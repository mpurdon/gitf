defmodule GiTF.Observability.Activity do
  @moduledoc """
  When the factory last did anything — the clock the idle-stop countdown
  runs on.

  The idle-stop timer samples `/health` every five minutes. A countdown
  kept from those samples misses everything that happens between two of
  them: on 2026-09-08 a mission was started, ran triage, research and
  requirements, and held for the operator entirely inside one interval,
  so the streak begun for a *previous* held mission carried through a
  kill, a deploy and four minutes of ghosts, and the box powered off
  fifteen seconds after the new question was raised.

  The daemon knows exactly when it was busy, so it keeps the timestamp
  itself: every ghost event and every mission phase transition touches
  it, and `/health` reports `idle_since` — the moment the current quiet
  began — for the script to measure from. No sampling gap can lose a
  burst, and nothing carries across a restart (boot touches too).
  """

  @key {__MODULE__, :last_activity_at}

  @doc "Records that the factory just did something."
  @spec touch() :: :ok
  def touch, do: :persistent_term.put(@key, DateTime.utc_now())

  @doc "When the factory last did something; boot time if nothing has happened since."
  @spec last_activity_at() :: DateTime.t()
  def last_activity_at do
    :persistent_term.get(@key)
  rescue
    ArgumentError -> boot_time()
  end

  @doc """
  When the current quiet began, or nil while busy. Callers pass the
  verdict they already computed so the two never disagree.
  """
  @spec idle_since(boolean()) :: DateTime.t() | nil
  def idle_since(true), do: last_activity_at()
  def idle_since(false), do: nil

  @doc false
  def attach do
    :telemetry.attach_many(
      "gitf-activity-touch",
      [
        [:gitf, :ghost, :spawned],
        [:gitf, :ghost, :completed],
        [:gitf, :ghost, :failed],
        [:gitf, :phase, :prompt_built]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(_event, _measurements, _metadata, _config), do: touch()

  defp boot_time do
    DateTime.from_unix!(:persistent_term.get(:gitf_boot_time))
  rescue
    _ -> DateTime.utc_now()
  end
end
