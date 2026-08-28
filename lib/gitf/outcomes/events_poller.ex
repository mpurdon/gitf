defmodule GiTF.Outcomes.EventsPoller do
  @moduledoc """
  Revives outcome tracking from the repository events feed.

  `GiTF.Outcomes.Tracker` polls each tracked PR individually and retires a
  record after 72 quiet hours — the right call for cost, but it means a PR
  that is merged, closed, or reviewed *after* that window is invisible
  forever, and so is anything that happens while the box is idle-stopped
  longer than the tracker's memory. GitHub webhooks cannot cover the gap:
  a delivery is attempted once, never retried, and the delivery log lasts
  3 days.

  `GET /repos/{owner}/{repo}/events` fixes both with one call per repo: it
  carries PR and review activity over a ~30-day window. This GenServer polls
  it for every repo that still has a non-terminal outcome record and, when
  an event postdates the record's last poll, calls `GiTF.Outcomes.revive/1`
  so the Tracker — which owns categorization, terminal side effects, and
  review intake — takes it from there. This module decides *whether to look
  again*, never *what the outcome is*.

  Costs nothing at rest: repos with no live records are skipped entirely,
  and unchanged feeds answer 304 via ETag, which GitHub does not count
  against the rate limit. The first poll runs shortly after boot, because
  boot is exactly the wake-from-idle moment the catch-up exists for.

  Gated on `:outcomes_enabled`, like the rest of the outcomes machinery.
  """

  use GenServer
  require Logger

  alias GiTF.Outcomes

  @name __MODULE__
  @default_interval_ms 5 * 60 * 1_000
  @boot_delay_ms 30_000
  @relevant_types ["PullRequestEvent", "PullRequestReviewEvent"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Forces an immediate poll pass. Intended for tests and operator nudges."
  @spec tick() :: :ok
  def tick, do: GenServer.cast(@name, :tick)

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @boot_delay_ms)
    {:ok, %{etags: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = safe_tick(state)
    schedule_next()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Outcomes.EventsPoller received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:tick, state) do
    {:noreply, safe_tick(state)}
  end

  defp safe_tick(state) do
    do_tick(state)
  rescue
    e ->
      Logger.warning("Outcomes.EventsPoller tick failed: #{Exception.message(e)}")
      state
  end

  # -- Poll pass --------------------------------------------------------------

  defp do_tick(state) do
    if Outcomes.enabled?() do
      revivable_by_sector()
      |> Enum.reduce(state, fn {sector_id, outcomes}, acc ->
        poll_sector(sector_id, outcomes, acc)
      end)
    else
      state
    end
  end

  # Non-terminal records grouped by sector. Terminal outcomes are settled
  # history — an event on a merged PR is not ours to act on — and a repo
  # with nothing revivable gets no API call at all.
  defp revivable_by_sector do
    Outcomes.all()
    |> Enum.filter(&revivable?/1)
    |> Enum.group_by(& &1.sector_id)
    |> Enum.reject(fn {sector_id, _} -> is_nil(sector_id) end)
  end

  defp poll_sector(sector_id, outcomes, state) do
    with {:ok, sector} <- GiTF.Sector.get(sector_id),
         true <- github_configured?(sector) do
      case GiTF.GitHub.repo_events(sector, etag: state.etags[sector_id]) do
        {:ok, events, etag} ->
          revived = process_events(events, outcomes)
          if revived > 0, do: GiTF.Outcomes.Tracker.tick()
          put_in(state.etags[sector_id], etag)

        :not_modified ->
          state

        {:error, reason} ->
          Logger.debug(
            "Outcomes.EventsPoller: events fetch for #{sector_id} failed: #{inspect(reason)}"
          )

          state
      end
    else
      _ -> state
    end
  end

  defp github_configured?(sector) do
    is_binary(Map.get(sector, :github_owner)) and is_binary(Map.get(sector, :github_repo))
  end

  # Returns the number of records revived.
  defp process_events(events, outcomes) do
    by_url = Map.new(outcomes, &{&1.pr_url, &1})

    events
    |> pr_activity()
    |> Enum.count(fn {url, event_time} ->
      case by_url[url] do
        nil -> false
        outcome -> maybe_revive(outcome, event_time)
      end
    end)
  end

  @doc """
  Collapses an events page to the latest PR activity per PR URL.

  Returns `[{pr_url, latest_event_time}]`. Public and pure for tests.
  """
  @spec pr_activity([map()]) :: [{String.t(), DateTime.t()}]
  def pr_activity(events) when is_list(events) do
    events
    |> Enum.filter(&(Map.get(&1, "type") in @relevant_types))
    |> Enum.flat_map(fn event ->
      url = get_in(event, ["payload", "pull_request", "html_url"])
      time = Outcomes.parse_iso8601(Map.get(event, "created_at"))
      if is_binary(url) and match?(%DateTime{}, time), do: [{url, time}], else: []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {url, times} -> {url, Enum.max(times, DateTime)} end)
  end

  defp maybe_revive(outcome, event_time) do
    if needs_revival?(outcome, event_time) do
      case Outcomes.revive(outcome.id) do
        {:ok, _} ->
          Logger.info(
            "Outcomes.EventsPoller: repo activity on #{outcome.pr_url} at " <>
              "#{DateTime.to_iso8601(event_time)} — revived outcome #{outcome.id}"
          )

          true

        {:error, reason} ->
          Logger.warning("Outcomes.EventsPoller: revive #{outcome.id} failed: #{inspect(reason)}")
          false
      end
    else
      false
    end
  end

  @doc """
  True when `event_time` postdates our last look at the outcome's PR.

  Comparing against `last_polled_at` (fall back to `first_tracked_at`) is
  what makes revival idempotent across restarts: the poller keeps no
  durable state, so after a reboot the same 30-day window is re-read, and
  without this check every stale record would be revived on every boot.
  Public and pure for tests.
  """
  @spec needs_revival?(map(), DateTime.t()) :: boolean()
  def needs_revival?(outcome, %DateTime{} = event_time) do
    case Map.get(outcome, :last_polled_at) || Map.get(outcome, :first_tracked_at) do
      %DateTime{} = seen -> DateTime.compare(event_time, seen) == :gt
      _ -> true
    end
  end

  defp revivable?(outcome) do
    category = Outcomes.parse_category(Map.get(outcome, :outcome_category))

    is_binary(Map.get(outcome, :pr_url)) and not Outcomes.terminal?(category)
  end

  defp schedule_next do
    interval =
      Application.get_env(:gitf, :timeouts, [])[:events_poll_interval_ms] ||
        @default_interval_ms

    Process.send_after(self(), :tick, interval)
  end
end
