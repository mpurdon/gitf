defmodule GiTF.Outcomes.Analyzer do
  @moduledoc """
  Pure categorization of a `GiTF.Outcomes` record into a terminal or
  transient category. Has no side effects; the tracker owns persistence.

  Precedence (first match wins):

    1. `revert_detected == true` → `:merged_reverted`
    2. `pr_state == "merged"` (no revert) → `:merged_clean`
    3. `pr_state == "closed"` and not merged → `:closed_unmerged`
    4. `changes_requested_count > 0` and still open → `:changes_requested`
    5. Open for >72h since first tracked → `:stale`
    6. Otherwise → `:pending`

  `:merged_clean` may be downgraded to `:merged_broke_main` when
  post-merge CI regresses — applied separately by the alerts layer after
  this returns.
  """

  @stale_window_seconds 72 * 3600

  @doc "Returns the category for the given outcome record."
  @spec categorize(map(), DateTime.t()) :: GiTF.Outcomes.category()
  def categorize(outcome, now \\ DateTime.utc_now()) do
    state = normalize_state(Map.get(outcome, :pr_state))
    merged? = state == "merged" or Map.get(outcome, :pr_merged_at) != nil
    reverted? = Map.get(outcome, :revert_detected, false) == true
    changes_requested? = Map.get(outcome, :changes_requested_count, 0) > 0

    cond do
      reverted? -> :merged_reverted
      merged? -> :merged_clean
      state == "closed" -> :closed_unmerged
      state == "open" and changes_requested? -> :changes_requested
      state == "open" and stale?(outcome, now) -> :stale
      true -> :pending
    end
  end

  @doc """
  True when nothing has happened on the PR for longer than the stale window.

  Measured from the last time the PR itself changed — not from when tracking
  began. Anchoring on `first_tracked_at` retired a PR purely for being old,
  which abandoned exactly the ones becoming interesting: a change request
  arrived on PR #8 an hour after its 72h elapsed, and the tracker had already
  stopped watching, so the review was never seen.

  Falls back to `first_tracked_at` for records written before activity was
  recorded, so an old row still ages out rather than being tracked forever.
  """
  @spec stale?(map(), DateTime.t()) :: boolean()
  def stale?(outcome, now \\ DateTime.utc_now()) do
    case Map.get(outcome, :last_activity_at) || Map.get(outcome, :first_tracked_at) do
      %DateTime{} = anchor ->
        DateTime.diff(now, anchor, :second) > @stale_window_seconds

      _ ->
        false
    end
  end

  @doc "Returns the stale window (seconds) used by the analyzer."
  @spec stale_window_seconds() :: non_neg_integer()
  def stale_window_seconds, do: @stale_window_seconds

  defp normalize_state(nil), do: nil
  defp normalize_state(s) when is_binary(s), do: String.downcase(s)
  defp normalize_state(s) when is_atom(s), do: Atom.to_string(s)
end
