defmodule GiTF.GitHub.ReviewIntake do
  @moduledoc """
  Turns a "request changes" review on a factory PR into a follow-up mission.

  Until now the loop stopped at the PR: the factory opened one, a human
  reviewed it, and the feedback stayed in GitHub. Acting on it meant
  writing a new mission by hand and restating what the reviewer already
  said.

  The follow-up mission is created with `target_branch` set to the PR's
  head, so `GiTF.Sync.merge_quest/1` builds on the branch that is already
  under review rather than off main, and `GiTF.Publish` reuses the
  existing PR for that head. The reviewer sees their PR update in place.

  ## What is deliberately not ingested

    * **Approvals and plain comments.** Only `changes_requested` states a
      concrete ask. A mission per drive-by comment is noise.
    * **Inline review comments** (`pull_request_review_comment`). They
      arrive one event per comment; the enclosing review is the unit of
      intent, and its body carries the summary. Those events still bump
      outcome polling, they just do not spawn work.
    * **PRs the factory did not open.** Intake only fires for a PR with a
      tracked outcome record. A webhook must never be able to point the
      factory at arbitrary repository work.

  Off by default (`:pr_review_intake_enabled`), like the rest of the
  intelligence layer.
  """

  require Logger

  alias GiTF.Missions
  alias GiTF.Outcomes

  @doc "True when review-driven follow-up missions are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :pr_review_intake_enabled, false)

  @doc """
  Handles a `pull_request_review` webhook payload.

  Returns `{:ok, :mission_created, mission}`, `{:ok, :ignored, reason}`, or
  `{:error, reason}`. Ignoring is the common case and is not a failure.
  """
  @spec dispatch(map()) :: {:ok, atom(), map() | nil} | {:error, term()}
  def dispatch(payload) do
    with :ok <- check(enabled?(), :disabled),
         :ok <- check(payload["action"] == "submitted", :not_submitted),
         review when is_map(review) <- payload["review"] || :no_review,
         :ok <- check(changes_requested?(review), :not_changes_requested),
         pr when is_map(pr) <- payload["pull_request"] || :no_pull_request,
         url when is_binary(url) <- pr["html_url"] || :no_url,
         outcome when is_map(outcome) <- Outcomes.get_by_pr_url(url) || :untracked_pr,
         :ok <- check(not handled?(outcome, review["id"]), :already_handled),
         head when is_binary(head) <- get_in(pr, ["head", "ref"]) || :no_head_ref do
      create_followup(outcome, pr, review, head, url)
    else
      {:ignored, reason} -> {:ok, :ignored, reason}
      reason when is_atom(reason) -> {:ok, :ignored, reason}
      {:error, _} = err -> err
    end
  end

  defp create_followup(outcome, pr, review, head, url) do
    attrs = %{
      goal: goal(pr, review),
      sector_id: Map.get(outcome, :sector_id),
      target_branch: head,
      source: "pr_review",
      source_issue: %{
        "pr_url" => url,
        "review_id" => review["id"],
        "review_url" => review["html_url"],
        "reviewer" => get_in(review, ["user", "login"]),
        "parent_mission_id" => Map.get(outcome, :mission_id)
      }
    }

    case Missions.create(attrs) do
      {:ok, mission} ->
        mark_handled(outcome, review["id"])

        Logger.info(
          "PR review intake: #{url} → mission #{mission.id} on branch #{head}"
        )

        {:ok, :mission_created, mission}

      {:error, reason} = err ->
        Logger.warning("PR review intake failed for #{url}: #{inspect(reason)}")
        err
    end
  end

  # The reviewer's own words are the specification — restating them in our
  # phrasing is how intent gets lost. The framing around them exists only to
  # tell the mission it is amending existing work, not starting fresh.
  defp goal(pr, review) do
    body = String.trim(review["body"] || "")

    feedback =
      if body == "",
        do: "The reviewer requested changes without leaving a summary. Read the inline comments on the PR.",
        else: body

    """
    Address the review feedback on PR ##{pr["number"]} (#{pr["title"]}).

    #{get_in(review, ["user", "login"]) || "A reviewer"} requested changes:

    #{feedback}

    This branch is already open as a pull request. Extend the work that is
    on it — do not revert it or start over. Address every point raised
    above; if a point cannot be addressed, say so explicitly rather than
    silently skipping it.
    """
  end

  defp changes_requested?(review) do
    String.downcase(to_string(review["state"] || "")) == "changes_requested"
  end

  # Dedupe lives on the outcome record because it is already the factory's
  # one row per PR. GitHub redelivers webhooks, and a redelivery must not
  # queue the same work twice.
  defp handled?(outcome, review_id) do
    review_id in (Map.get(outcome, :handled_reviews) || [])
  end

  defp mark_handled(outcome, review_id) do
    Outcomes.update(outcome.id, fn o ->
      handled = Map.get(o, :handled_reviews) || []
      Map.put(o, :handled_reviews, Enum.uniq([review_id | handled]))
    end)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:ignored, reason}
end
