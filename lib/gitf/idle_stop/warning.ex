defmodule GiTF.IdleStop.Warning do
  @moduledoc """
  Raises `idle_stop_imminent` a few minutes before the box powers itself off.

  Held missions no longer keep a box awake (0.65.279), so this warning is
  the operator's last chance to say "wait" — and the answer wakes the box
  anyway, so a missed warning costs a minute of boot, not the work.

  It is a factory ALERT, not a Discord feature: it takes the same path as
  every other alert (log, webhook, any channel plugin), which is the test
  that it sits at the right altitude. The countdown is the one
  `rel/gitf-idle-stop.sh` runs — `IdleStop.projected_stop_at/1` does the
  script's arithmetic — so the warning and the poweroff agree by
  construction rather than by two clocks staying in step.

  One warning per idle episode: the dedup key is `idle_since`, so a box
  that stays quiet re-warns only when a new quiet begins. A hold set after
  the warning moves `projected_stop_at` out of the window and the next
  tick simply finds nothing imminent.
  """

  use GenServer

  require Logger

  @tick_ms :timer.minutes(1)
  @default_warn_minutes 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    tick = Keyword.get(opts, :tick_ms, @tick_ms)
    if tick > 0, do: Process.send_after(self(), :tick, tick)
    {:ok, %{tick_ms: tick}}
  end

  @impl true
  def handle_info(:tick, state) do
    check()
    if state.tick_ms > 0, do: Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  @doc """
  One pass: warn when the projected stop is within the warning window.
  Public so a test (and an operator at a console) can run it on demand.
  """
  @spec check() :: :warned | :quiet
  def check do
    %{idle_since: idle_since, held: held} = GiTF.Observability.Health.idle_state()

    case GiTF.IdleStop.projected_stop_at(idle_since) do
      %DateTime{} = stop_at ->
        minutes_left = div(DateTime.diff(stop_at, DateTime.utc_now(), :second), 60)

        if minutes_left <= warn_minutes() do
          warn(stop_at, idle_since, max(minutes_left, 0), length(held))
          :warned
        else
          :quiet
        end

      nil ->
        :quiet
    end
  rescue
    e ->
      Logger.debug("IdleStop.Warning: check skipped (#{Exception.message(e)})")
      :quiet
  end

  defp warn(stop_at, idle_since, minutes_left, held) do
    GiTF.Observability.Alerts.dispatch_webhook(
      :idle_stop_imminent,
      "The factory has been idle since #{fmt(idle_since)} and powers off at " <>
        "#{fmt(stop_at)} (~#{minutes_left} min). Hold it if you still need it.",
      dedup_key: "idle_stop_imminent:#{DateTime.to_iso8601(idle_since)}",
      data: %{
        stop_at: DateTime.to_iso8601(stop_at),
        idle_since: DateTime.to_iso8601(idle_since),
        minutes_left: minutes_left,
        held_missions: held
      }
    )
  end

  defp warn_minutes do
    case Integer.parse(System.get_env("GITF_IDLE_STOP_WARN_MINUTES") || "") do
      {n, _} when n > 0 -> n
      _ -> @default_warn_minutes
    end
  end

  defp fmt(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%H:%M UTC")
end
