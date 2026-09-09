defmodule GiTF.Cabinet.Fleet do
  @moduledoc """
  Waking, stopping and watching ministry boxes.

  EC2 calls go through an injectable runner (default: the `aws` CLI with
  the Cabinet's instance role — same-account, and the role is scoped to
  Start/Stop/Describe on `gitf:ministry`-tagged instances). Box health
  is the Section's own public `/api/v1/health`.
  """

  require Logger

  @unknown_box %{state: :unknown, launched_at: nil}

  @doc """
  What EC2 knows about the ministry's box: `state` ("running" |
  "stopped" | "pending" | "stopping" | … | :unknown) and `launched_at`
  (the most recent start — EC2 keeps that, but NOT when a box stopped:
  an idle-stop is an instance-initiated shutdown and its transition
  reason carries no timestamp, which is why `observe/1` exists).
  """
  def describe(%{instance_id: id}) when is_binary(id) and id != "" do
    query =
      "Reservations[0].Instances[0].{state:State.Name,launched_at:LaunchTime}"

    with {out, 0} <-
           runner().ec2([
             "describe-instances",
             "--instance-ids",
             id,
             "--query",
             query,
             "--output",
             "json"
           ]),
         {:ok, %{"state" => state} = box} when is_binary(state) <- Jason.decode(to_string(out)) do
      %{state: state, launched_at: parse_time(box["launched_at"])}
    else
      _ -> @unknown_box
    end
  end

  def describe(_), do: @unknown_box

  @doc "EC2 state for the ministry: \"running\" | \"stopped\" | \"pending\" | … | :unknown."
  def instance_state(ministry), do: describe(ministry).state

  @doc """
  Describes the box AND remembers what it saw, so the fleet has a
  history EC2 does not keep: `box.state_since` is the moment the state
  began — the launch time for a running box, the moment the Cabinet
  noticed for anything else (nil until a transition has been seen).
  A transition lands in the activity feed as the Cabinet's own
  observation. Returns the ministry with `:box` filled in; an unknown
  answer (no instance id, EC2 unreachable) is not remembered.
  """
  def observe(%{id: id} = ministry) do
    prev = ministry[:box] || %{}
    now = DateTime.utc_now()

    case describe(ministry) do
      %{state: :unknown} = box ->
        Map.put(ministry, :box, Map.merge(prev, box))

      %{state: state} = box ->
        since =
          cond do
            state == "running" -> box.launched_at || prev[:state_since] || now
            state == prev[:state] -> prev[:state_since]
            prev[:state] == nil -> nil
            true -> now
          end

        box = Map.put(box, :state_since, since)

        if prev[:state] != nil and state != prev[:state] do
          GiTF.Cabinet.Activity.record("cabinet", "observed", ministry.slug, state)
        end

        if box != Map.take(prev, Map.keys(box)) do
          GiTF.Cabinet.Registry.update(id, &Map.put(&1, :box, box))
        end

        Map.put(ministry, :box, box)
    end
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  def wake(%{instance_id: id} = ministry) when is_binary(id) and id != "" do
    Logger.info("Cabinet: waking #{ministry.slug} (#{id})")

    case runner().ec2(["start-instances", "--instance-ids", id]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:ec2, code, String.slice(to_string(out), 0, 200)}}
    end
  end

  def wake(_), do: {:error, :no_instance_id}

  def stop(%{instance_id: id} = ministry) when is_binary(id) and id != "" do
    Logger.info("Cabinet: stopping #{ministry.slug} (#{id})")

    case runner().ec2(["stop-instances", "--instance-ids", id]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:ec2, code, String.slice(to_string(out), 0, 200)}}
    end
  end

  def stop(_), do: {:error, :no_instance_id}

  @doc "The Section's own health verdict, or :unreachable (asleep boxes are unreachable, not broken)."
  def health(%{url: url}) when is_binary(url) and url != "" do
    case Req.get(
           url: String.trim_trailing(url, "/") <> "/api/v1/health",
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, _} -> :unreachable
    end
  end

  def health(_), do: :unreachable

  @doc """
  Wakes the ministry and waits until its Section answers health, up to
  `timeout_ms` (default 180s — a cold box takes ~60-90s).
  """
  def wake_and_await(ministry, timeout_ms \\ 180_000) do
    with :ok <- wake(ministry) do
      await_healthy(ministry, timeout_ms)
    end
  end

  @doc "Polls the Section's health every 5s until it answers or `timeout_ms` passes."
  def await_healthy(ministry, timeout_ms) do
    await(ministry, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await(ministry, deadline) do
    case health(ministry) do
      {:ok, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :wake_timeout}
        else
          Process.sleep(5_000)
          await(ministry, deadline)
        end
    end
  end

  defp runner do
    Application.get_env(:gitf, :cabinet_ec2_runner, GiTF.Cabinet.Fleet.AwsCli)
  end

  defmodule AwsCli do
    @moduledoc false
    def ec2(args), do: System.cmd("aws", ["ec2" | args], stderr_to_stdout: true)
  end
end
