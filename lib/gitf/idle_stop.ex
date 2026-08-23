defmodule GiTF.IdleStop do
  @moduledoc """
  Time-boxed overrides for the idle-stop shutdown policy.

  The box powers itself off after `GITF_IDLE_STOP_MINUTES` of idleness — a
  systemd timer running `rel/gitf-idle-stop.sh`, not an AWS feature. That is
  right for the steady state and wrong while you are waiting on something:
  a review to land, a slow external job, a debugging session.

  An override says both *how patient* to be and *for how long to stay that
  patient*: "for the next 4 hours, wait an hour of idleness before stopping."
  The duration is mandatory. A hold with no expiry is how a box stays up for
  a month and the cost shows up on a bill nobody was watching, so there is
  deliberately no way to express one — `disable/1` is just a very patient
  override, and it still expires.

  The daemon writes the override; the root-run shell script reads it. The
  file therefore lives under `GITF_HOME`, which the daemon owns, rather than
  `/etc/gitf`, which it must not write to.
  """

  require Logger

  # Bounds exist because this spends money. The ceiling is not a safety
  # property against a determined operator — it is a guard against a typo
  # turning "240 minutes" into "240 hours".
  @max_duration_minutes 24 * 60
  @max_idle_minutes 12 * 60

  @type t :: %{
          idle_minutes: pos_integer(),
          expires_at: DateTime.t(),
          reason: String.t() | nil,
          set_at: DateTime.t()
        }

  @doc "Path of the override file the shutdown script reads."
  @spec path() :: String.t()
  def path do
    home = System.get_env("GITF_HOME") || Path.expand("~/.gitf")
    Path.join(home, "idle-stop-override.json")
  end

  @doc """
  Sets a time-boxed idle-stop override.

  `idle_minutes` is how long the factory must sit idle before powering off
  while the override is active; `duration_minutes` is how long the override
  itself lasts. Both are required and both are bounded.

  Returns `{:ok, override}` or `{:error, reason}`.
  """
  @spec set(pos_integer(), pos_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def set(idle_minutes, duration_minutes, opts \\ []) do
    with :ok <- validate(idle_minutes, 1, @max_idle_minutes, :idle_minutes),
         :ok <- validate(duration_minutes, 1, @max_duration_minutes, :duration_minutes) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expires_at = DateTime.add(now, duration_minutes * 60, :second)

      override = %{
        idle_minutes: idle_minutes,
        expires_at: expires_at,
        reason: Keyword.get(opts, :reason),
        set_at: now
      }

      case write(override) do
        :ok ->
          Logger.info(
            "Idle-stop override: #{idle_minutes}m idle threshold until #{DateTime.to_iso8601(expires_at)}"
          )

          {:ok, override}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  The active override, or `nil` when none is set or it has expired.

  Expiry is evaluated on read rather than swept, so a stale file is inert
  even if nothing has cleaned it up.
  """
  @spec active() :: t() | nil
  def active do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"idle_minutes" => idle, "expires_at" => exp}} <- Jason.decode(body),
         {:ok, expires_at, _} <- DateTime.from_iso8601(exp),
         :lt <- DateTime.compare(DateTime.utc_now(), expires_at) do
      %{
        idle_minutes: idle,
        expires_at: expires_at,
        reason: body |> Jason.decode!() |> Map.get("reason"),
        set_at: nil
      }
    else
      _ -> nil
    end
  end

  @doc "Removes any override, restoring the configured default immediately."
  @spec clear() :: :ok
  def clear do
    case File.rm(path()) do
      :ok -> Logger.info("Idle-stop override cleared")
      _ -> :ok
    end

    :ok
  end

  @doc """
  Convenience for "keep the box up for a while": a very patient override.

  Still expires — see the module note on why there is no permanent hold.
  """
  @spec disable(pos_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def disable(duration_minutes, opts \\ []),
    do: set(@max_idle_minutes, duration_minutes, opts)

  @doc "Minutes remaining on the active override, or 0."
  @spec remaining_minutes() :: non_neg_integer()
  def remaining_minutes do
    case active() do
      nil -> 0
      %{expires_at: exp} -> max(div(DateTime.diff(exp, DateTime.utc_now(), :second), 60), 0)
    end
  end

  defp write(override) do
    payload =
      override
      |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
      |> Map.update!(:set_at, &DateTime.to_iso8601/1)
      |> Jason.encode!()

    file = path()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, payload) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not write idle-stop override to #{file}: #{inspect(reason)}")
        {:error, {:write_failed, reason}}
    end
  end

  defp validate(value, min, max, name) when is_integer(value) do
    cond do
      value < min -> {:error, {:too_small, name, min}}
      value > max -> {:error, {:too_large, name, max}}
      true -> :ok
    end
  end

  defp validate(_, _, _, name), do: {:error, {:not_an_integer, name}}
end
