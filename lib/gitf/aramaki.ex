defmodule GiTF.Aramaki do
  @moduledoc """
  Aramaki — the project-management / admission layer above the factory.

  Named for Section 9's chief, who decides which cases the team takes. Where
  the Major orchestrates *how* a mission runs, Aramaki decides *which* work
  becomes a mission and *when* it starts.

  Responsibilities:

    * **Ingest** signals — GitHub issues (via `Aramaki.Intake` off the webhook),
      and any other pending, un-started missions (inbox / Sentry). This also
      closes a long-standing gap: pending missions from those sources were
      never auto-started.
    * **Admit** work within capacity — a periodic tick (and event nudges) start
      pending Aramaki missions in priority order, but only while
      `Aramaki.Policy.capacity_available?/1` holds (factory daily budget +
      concurrent-mission cap). Admission is a multiplier on every runaway risk,
      so the gate is deliberately conservative.
    * **Report** back on GitHub — `Aramaki.Lifecycle` comments/labels the source
      issue as the mission moves, links the PR on publish, and closes the issue
      on merge.

  Untrusted-input safety: issue bodies are attacker-controllable, and ghosts
  now run sandboxed (see `GiTF.Sandbox`), but admission is still label-gated
  (`gitf:build`) so only maintainer-approved issues ever reach the factory.

  Enable with config `[:aramaki, :enabled] = true` (default false) — Aramaki is
  opt-in; without it the factory behaves exactly as before.
  """

  use GenServer
  require Logger

  alias GiTF.Aramaki.Policy

  @tick_interval_ms 30_000

  # -- Client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether Aramaki is enabled (config `[:aramaki, :enabled]`, default false)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :aramaki, []) |> Keyword.get(:enabled, false) == true
  end

  @doc "Force an admission tick now (used by tests + webhook nudges)."
  @spec tick() :: :ok
  def tick do
    if pid = Process.whereis(__MODULE__), do: send(pid, :tick)
    :ok
  end

  # -- Server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    admit_pending()
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:consider, _mission_id}, state) do
    # An intake just created a pending mission — try to admit immediately
    # rather than waiting for the next tick.
    admit_pending()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Admission -------------------------------------------------------------

  @doc """
  Starts as many pending Aramaki missions as capacity allows, highest priority
  first. Public so tests can drive it deterministically. Returns the number
  admitted.
  """
  @spec admit_pending() :: non_neg_integer()
  def admit_pending do
    active = active_count()

    case Policy.capacity_available?(active) do
      {:full, reason} ->
        if pending_aramaki_missions() != [] do
          Logger.info("Aramaki: capacity full (#{reason}); holding pending work")
        end

        0

      {:ok, slots} ->
        pending_aramaki_missions()
        |> Enum.sort_by(&Map.get(&1, :aramaki_priority, 2))
        |> Enum.take(slots)
        |> Enum.reduce(0, fn mission, admitted ->
          case admit(mission) do
            :ok -> admitted + 1
            _ -> admitted
          end
        end)
    end
  rescue
    e ->
      Logger.warning("Aramaki.admit_pending crashed: #{Exception.message(e)}")
      0
  end

  defp admit(mission) do
    Logger.info("Aramaki: starting mission #{mission.id} (priority #{Map.get(mission, :aramaki_priority, 2)})")

    case GiTF.Major.Orchestrator.start_quest(mission.id) do
      {:ok, _} ->
        GiTF.Aramaki.Lifecycle.on_admitted(mission)
        :ok

      {:error, reason} ->
        Logger.warning("Aramaki: start_quest failed for #{mission.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Pending missions that Aramaki owns (source == github_issue and still
  # pending). We deliberately do NOT auto-start arbitrary pending missions —
  # only ones that came through Aramaki's admission gate.
  defp pending_aramaki_missions do
    GiTF.Archive.all(:missions)
    |> Enum.filter(fn m ->
      Map.get(m, :status) == "pending" and Map.get(m, :source) == "github_issue"
    end)
  end

  defp active_count do
    GiTF.Archive.all(:missions)
    |> Enum.count(fn m ->
      Map.get(m, :source) == "github_issue" and
        Map.get(m, :status) in GiTF.Missions.active_statuses()
    end)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
