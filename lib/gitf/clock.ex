defmodule GiTF.Clock do
  @moduledoc """
  Awake-time clock for a machine that sleeps.

  The box idle-stops daily, so wall-clock gaps of hours are routine — and
  every deadline computed as `now - inserted_at` misfires on the first tick
  after wake (approvals "timing out" during hours nobody could act,
  missions "exceeding max age" while powered off). This module maintains a
  heartbeat file; a missing stretch of heartbeats is recorded as a sleep
  interval, and `awake_elapsed/2` subtracts those intervals from wall-clock
  age. When the GenServer isn't running (tests, thin-client CLI), there are
  no recorded intervals and everything degrades to plain wall-clock — the
  previous behavior.

  Also provides `in_boot_grace?/0`: a short post-boot quiet period during
  which destructive automatic actions (auto-approve, auto-fail, stale
  cleanup) should hold, so a wake never triggers an irreversible storm.
  """

  use GenServer
  require Logger

  @tick_ms 60_000
  # A heartbeat gap longer than this means the VM wasn't running.
  @gap_threshold_s 180
  @max_intervals 500
  @pt_intervals {__MODULE__, :intervals}
  @pt_boot {__MODULE__, :boot_mono}

  # -- Public API --------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Seconds elapsed since `since`, excluding recorded sleep intervals.
  With no recorded intervals this equals wall-clock elapsed seconds.
  """
  @spec awake_elapsed(DateTime.t() | nil, DateTime.t()) :: non_neg_integer()
  def awake_elapsed(since, now \\ DateTime.utc_now())
  def awake_elapsed(nil, _now), do: 0

  def awake_elapsed(%DateTime{} = since, now) do
    wall = DateTime.diff(now, since, :second)

    asleep =
      sleep_intervals()
      |> Enum.map(fn {gap_start, gap_end} ->
        overlap_seconds(gap_start, gap_end, since, now)
      end)
      |> Enum.sum()

    max(wall - asleep, 0)
  end

  @doc "Recorded sleep intervals, newest last: [{gap_start, gap_end}]."
  def sleep_intervals, do: :persistent_term.get(@pt_intervals, [])

  @doc """
  True during the first minutes after daemon boot (default 300s,
  `:boot_grace_seconds`). False when the clock isn't running.
  """
  def in_boot_grace? do
    case :persistent_term.get(@pt_boot, nil) do
      nil ->
        false

      boot_mono ->
        grace = Application.get_env(:gitf, :boot_grace_seconds, 300)
        System.monotonic_time(:second) - boot_mono < grace
    end
  end

  @doc false
  # Test hook: inject intervals without the GenServer.
  def put_intervals_for_test(intervals), do: :persistent_term.put(@pt_intervals, intervals)

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :state_path) || default_state_path()
    state = load_state(path)
    now = DateTime.utc_now()

    intervals =
      case state[:last_tick] do
        %DateTime{} = last when true ->
          gap = DateTime.diff(now, last, :second)

          if gap > @gap_threshold_s do
            Logger.info("Clock: detected #{gap}s sleep interval (#{last} -> #{now})")
            append_interval(state[:intervals] || [], {last, now})
          else
            state[:intervals] || []
          end

        _ ->
          state[:intervals] || []
      end

    :persistent_term.put(@pt_intervals, intervals)
    :persistent_term.put(@pt_boot, System.monotonic_time(:second))
    persist(path, intervals, now)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{path: path, intervals: intervals, last_tick: now}}
  end

  @impl true
  def handle_info(:tick, %{path: path, intervals: intervals, last_tick: last} = state) do
    now = DateTime.utc_now()
    gap = DateTime.diff(now, last, :second)

    intervals =
      if gap > @gap_threshold_s do
        # The scheduler can only be this late if the VM was suspended
        # (stop/start doesn't reach here — init handles that path).
        Logger.info("Clock: detected #{gap}s suspension (#{last} -> #{now})")
        updated = append_interval(intervals, {last, now})
        :persistent_term.put(@pt_intervals, updated)
        updated
      else
        intervals
      end

    persist(path, intervals, now)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | intervals: intervals, last_tick: now}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ---------------------------------------------------------------

  defp overlap_seconds(gap_start, gap_end, since, now) do
    o_start = if DateTime.compare(gap_start, since) == :lt, do: since, else: gap_start
    o_end = if DateTime.compare(gap_end, now) == :gt, do: now, else: gap_end

    case DateTime.compare(o_end, o_start) do
      :gt -> DateTime.diff(o_end, o_start, :second)
      _ -> 0
    end
  end

  defp append_interval(intervals, interval),
    do: Enum.take([interval | Enum.reverse(intervals)] |> Enum.reverse(), -@max_intervals)

  defp default_state_path, do: Path.join(GiTF.global_config_dir(), "clock.etf")

  defp load_state(path) do
    with {:ok, bin} <- File.read(path),
         term when is_map(term) <- safe_decode(bin) do
      term
    else
      _ -> %{}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> %{}
  end

  defp persist(path, intervals, last_tick) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(%{intervals: intervals, last_tick: last_tick}))
  rescue
    e -> Logger.warning("Clock: could not persist heartbeat: #{Exception.message(e)}")
  end
end
