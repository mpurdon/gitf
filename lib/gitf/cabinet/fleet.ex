defmodule GiTF.Cabinet.Fleet do
  @moduledoc """
  Waking, stopping and watching ministry boxes.

  EC2 calls go through an injectable runner (default: the `aws` CLI with
  the Cabinet's instance role — same-account, and the role is scoped to
  Start/Stop/Describe on `gitf:ministry`-tagged instances). Box health
  is the Section's own public `/api/v1/health`.
  """

  require Logger

  @doc "EC2 state for the ministry: \"running\" | \"stopped\" | \"pending\" | … | :unknown."
  def instance_state(%{instance_id: id}) when is_binary(id) and id != "" do
    case runner().ec2([
           "describe-instances",
           "--instance-ids",
           id,
           "--query",
           "Reservations[0].Instances[0].State.Name",
           "--output",
           "text"
         ]) do
      {out, 0} -> out |> to_string() |> String.trim()
      _ -> :unknown
    end
  end

  def instance_state(_), do: :unknown

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
      await_healthy(ministry, System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp await_healthy(ministry, deadline) do
    case health(ministry) do
      {:ok, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :wake_timeout}
        else
          Process.sleep(5_000)
          await_healthy(ministry, deadline)
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
