defmodule GiTF.Outcomes do
  @moduledoc """
  Post-completion outcome tracking for missions that opened a PR.

  Closes the learning loop the factory was missing: every mission emits a
  PR URL, but until now nothing watched whether that PR was merged,
  closed, or reverted. Outcomes records one row per tracked mission and
  is driven by `GiTF.Outcomes.Tracker` (periodic polling) and
  `GiTF.Outcomes.Analyzer` (pure categorization).

  Feature-flagged via `:outcomes_enabled`; when disabled
  `start_tracking/2` is a no-op and `list_open/0` returns `[]`.
  """

  alias GiTF.Archive

  @collection :mission_outcomes

  @type category ::
          :pending
          | :merged_clean
          | :merged_reverted
          | :closed_unmerged
          | :changes_requested
          | :stale
          | :merged_broke_main

  @categories [
    :pending,
    :merged_clean,
    :merged_reverted,
    :closed_unmerged,
    :changes_requested,
    :stale,
    :merged_broke_main
  ]

  @terminal_categories [:merged_clean, :merged_reverted, :closed_unmerged, :merged_broke_main]
  @negative_terminal_categories [:merged_reverted, :closed_unmerged, :merged_broke_main]

  @type t :: %{
          id: String.t(),
          mission_id: String.t(),
          sector_id: String.t() | nil,
          pr_url: String.t() | nil,
          pr_state: String.t() | nil,
          pr_merged_at: DateTime.t() | nil,
          pr_closed_at: DateTime.t() | nil,
          reviews: [map()],
          changes_requested_count: non_neg_integer(),
          revert_detected: boolean(),
          outcome_category: category(),
          first_tracked_at: DateTime.t(),
          last_polled_at: DateTime.t() | nil,
          next_poll_at: DateTime.t() | nil,
          poll_count: non_neg_integer(),
          tracking_stopped: boolean(),
          stopped_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Returns the set of outcome categories considered terminal."
  @spec terminal_categories() :: [category()]
  def terminal_categories, do: @terminal_categories

  @doc "Returns the terminal categories that represent a failed outcome."
  @spec negative_terminal_categories() :: [category()]
  def negative_terminal_categories, do: @negative_terminal_categories

  @doc """
  All terminal outcomes (optionally filtered by sector) via the Archive
  index. Cheap union across the 4 terminal categories.
  """
  @spec terminal_outcomes(String.t() | nil) :: [t()]
  def terminal_outcomes(sector_id \\ nil)

  def terminal_outcomes(nil) do
    Enum.flat_map(@terminal_categories, fn cat ->
      GiTF.Archive.by_index(@collection, :outcome_category, cat)
    end)
  end

  def terminal_outcomes(sector_id) when is_binary(sector_id) do
    GiTF.Archive.by_index(@collection, :sector_id, sector_id)
    |> Enum.filter(&(&1.outcome_category in @terminal_categories))
  end

  @doc "Parses a string category from external callers (MCP, etc.) into an atom."
  @spec parse_category(String.t() | atom() | nil) :: category() | nil
  def parse_category(nil), do: nil
  def parse_category(cat) when cat in @categories, do: cat

  def parse_category(str) when is_binary(str) do
    try do
      atom = String.to_existing_atom(str)
      if atom in @categories, do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  def parse_category(_), do: nil

  @doc """
  Begin tracking a mission's PR. No-op when `:outcomes_enabled` is false
  or when the mission already has an outcome record.

  `mission` is a mission map (needs at least `:id`, `:sector_id`).
  `pr_url` is the PR URL returned by the publish phase; when `nil` or
  empty no record is created.
  """
  @spec start_tracking(map(), String.t() | nil) :: {:ok, t()} | :skip | {:error, term()}
  def start_tracking(_mission, pr_url) when pr_url in [nil, ""], do: :skip

  def start_tracking(mission, pr_url) when is_binary(pr_url) do
    if enabled?() do
      case get_for_mission(mission.id) do
        nil ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          record = %{
            mission_id: mission.id,
            sector_id: Map.get(mission, :sector_id),
            pr_url: pr_url,
            pr_state: "open",
            pr_merged_at: nil,
            pr_closed_at: nil,
            reviews: [],
            changes_requested_count: 0,
            revert_detected: false,
            outcome_category: :pending,
            first_tracked_at: now,
            last_polled_at: nil,
            next_poll_at: now,
            poll_count: 0,
            tracking_stopped: false,
            stopped_reason: nil
          }

          Archive.insert(@collection, record)

        existing ->
          {:ok, existing}
      end
    else
      :skip
    end
  end

  @doc "Fetches an outcome by ID."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Archive.get(@collection, id)

  @doc "Returns the outcome record for a given mission, or nil."
  @spec get_for_mission(String.t()) :: t() | nil
  def get_for_mission(mission_id) when is_binary(mission_id) do
    case Archive.by_index(@collection, :mission_id, mission_id) do
      [record | _] -> record
      [] -> nil
    end
  end

  @doc "Returns the outcome record for a given PR URL, or nil."
  @spec get_by_pr_url(String.t()) :: t() | nil
  def get_by_pr_url(pr_url) when is_binary(pr_url) do
    case Archive.by_index(@collection, :pr_url, pr_url) do
      [record | _] -> record
      [] -> nil
    end
  end

  @doc """
  Returns the list of outcomes currently being tracked (i.e. not stopped).
  When `:outcomes_enabled` is false, returns `[]` unconditionally so
  `Tracker` has zero work to do.
  """
  @spec list_open() :: [t()]
  def list_open do
    if enabled?() do
      Archive.by_index(@collection, :tracking_stopped, false)
    else
      []
    end
  end

  @doc "Returns all outcomes regardless of tracking status."
  @spec all() :: [t()]
  def all, do: Archive.all(@collection)

  @doc """
  Atomically updates an outcome record. Closure semantics mirror
  `Archive.update/3`.
  """
  @spec update(String.t(), (t() -> t() | {:ok, t()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def update(id, update_fn), do: Archive.update(@collection, id, update_fn)

  @doc """
  Stops tracking an outcome. Sets `tracking_stopped: true` and records
  `stopped_reason`. Idempotent — re-stopping is a no-op.
  """
  @spec stop_tracking(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def stop_tracking(id, reason) when is_binary(reason) do
    update(id, fn outcome ->
      if outcome.tracking_stopped do
        outcome
      else
        Map.merge(outcome, %{
          tracking_stopped: true,
          stopped_reason: reason,
          next_poll_at: nil
        })
      end
    end)
  end

  @doc "True when the factory is configured to track post-completion outcomes."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :outcomes_enabled, false) == true

  @doc "True when the given category is terminal (no further polling)."
  @spec terminal?(category()) :: boolean()
  def terminal?(category), do: category in @terminal_categories

  @doc """
  Resolves the repository path for an outcome or mission-like map,
  preferring the denormalized `:sector_id` on the outcome before falling
  back to the mission record.
  """
  @spec repo_path_for(map()) :: {:ok, String.t()} | {:error, :not_found}
  def repo_path_for(%{} = record) do
    sector_id =
      Map.get(record, :sector_id) ||
        case Map.get(record, :mission_id) do
          mid when is_binary(mid) ->
            case GiTF.Archive.get(:missions, mid) do
              %{sector_id: sid} -> sid
              _ -> nil
            end

          _ ->
            nil
        end

    with sid when is_binary(sid) <- sector_id,
         %{path: path} when is_binary(path) <- GiTF.Archive.get(:sectors, sid) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Parses an ISO-8601 string into a `DateTime` truncated to seconds, or nil."
  @spec parse_iso8601(String.t() | DateTime.t() | nil) :: DateTime.t() | nil
  def parse_iso8601(nil), do: nil
  def parse_iso8601(%DateTime{} = dt), do: dt

  def parse_iso8601(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end
end
