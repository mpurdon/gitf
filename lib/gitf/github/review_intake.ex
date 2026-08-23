defmodule GiTF.GitHub.ReviewIntake do
  @moduledoc """
  Turns a "request changes" review on a factory PR into a follow-up mission.

  Until now the loop stopped at the PR: the factory opened one, a human
  reviewed it, and the feedback stayed in GitHub. Acting on it meant writing
  a new mission by hand and restating what the reviewer already said.

  The follow-up mission is created with `target_branch` set to the PR's head,
  so `GiTF.Sync.merge_quest/1` builds on the branch that is already under
  review rather than off main, and `GiTF.Publish` reuses the existing PR for
  that head. The reviewer sees their PR update in place.

  ## Two ways in, one decision

  `dispatch/1` handles a `pull_request_review` webhook — immediate, but only
  while the box is up, and GitHub never retries a failed delivery.

  `from_poll/2` is fed by `GiTF.Outcomes.Tracker`, which already fetches every
  tracked PR's reviews on each poll. Slower, but it cannot miss anything: a
  review left while the box was stopped is picked up whenever it next wakes.

  Both funnel into `admit/3`, so the refusals below are stated once.

  ## What is deliberately not ingested

    * **Approvals and plain comments.** Only `changes_requested` states a
      concrete ask. A mission per drive-by comment is noise.
    * **Inline review comments.** They arrive one webhook event per comment;
      the enclosing review is the unit of intent.
    * **PRs the factory did not open.** Intake only fires for a PR with a
      tracked outcome record. A webhook must never be able to point the
      factory at arbitrary repository work.
    * **The factory's own reviews**, via `Policy.admit_review?/2` — otherwise
      a self-review is a loop.

  ## Capacity

  Admission goes through `GiTF.Aramaki.Policy.capacity_available?/1`, the same
  gate issue intake uses, counting against the same ceiling. Without it, ten
  changes-requested reviews would create ten uncapped missions — not an
  internet DDoS, but work amplification by anyone with repository access.

  When capacity is full the poller path **defers**: the review is not marked
  handled, so the next poll retries it. That is backpressure without a queue,
  and it is only possible on the poller path — the webhook path has no second
  chance, because GitHub does not retry.

  Off by default (`:pr_review_intake_enabled`).
  """

  require Logger

  alias GiTF.Aramaki.Policy
  alias GiTF.Missions
  alias GiTF.Outcomes

  @doc "True when review-driven follow-up missions are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :pr_review_intake_enabled, false)

  @doc """
  Handles a `pull_request_review` webhook payload.

  Returns `{:ok, :mission_created, mission}`, `{:ok, :ignored, reason}`,
  `{:ok, :deferred, reason}`, or `{:error, reason}`.
  """
  @spec dispatch(map()) :: {:ok, atom(), map() | nil} | {:error, term()}
  def dispatch(payload) do
    with :ok <- check(enabled?(), :disabled),
         :ok <- check(payload["action"] == "submitted", :not_submitted),
         review when is_map(review) <- payload["review"] || :no_review,
         pr when is_map(pr) <- payload["pull_request"] || :no_pull_request,
         url when is_binary(url) <- pr["html_url"] || :no_url,
         outcome when is_map(outcome) <- Outcomes.get_by_pr_url(url) || :untracked_pr do
      admit(outcome, review, pr_context(pr))
    else
      {:ignored, reason} -> {:ok, :ignored, reason}
      reason when is_atom(reason) -> {:ok, :ignored, reason}
      {:error, _} = err -> err
    end
  end

  @doc """
  Handles a review seen by the outcome poller.

  `reviews` are the normalised review maps already on the outcome record
  (`%{author:, state:, submitted_at:, body:}`) — no extra API call is made.
  Returns the list of results, one per review that was acted on.
  """
  @spec from_poll(map(), [map()]) :: [{:ok, atom(), map() | nil} | {:error, term()}]
  def from_poll(outcome, reviews) when is_list(reviews) do
    if enabled?() do
      reviews
      |> Enum.filter(&changes_requested?/1)
      |> Enum.map(&admit(outcome, &1, poll_context(outcome)))
      |> Enum.reject(&match?({:ok, :ignored, :already_handled}, &1))
    else
      []
    end
  end

  def from_poll(_outcome, _), do: []

  # -- The one decision ------------------------------------------------------

  defp admit(outcome, review, context) do
    with :admit <- Policy.admit_review?(review, bot_login: bot_login()),
         :ok <- check(not handled?(outcome, review), :already_handled),
         {:ok, _slots} <- capacity(),
         head when is_binary(head) <- context.head_ref || :no_head_ref do
      create_followup(outcome, review, context, head)
    else
      {:reject, reason} -> {:ok, :ignored, reason}
      {:ignored, reason} -> {:ok, :ignored, reason}
      # Full is NOT handled: leaving the review unmarked is what makes the
      # next poll retry it.
      {:full, reason} -> {:ok, :deferred, reason}
      reason when is_atom(reason) -> {:ok, :ignored, reason}
      {:error, _} = err -> err
    end
  end

  defp capacity, do: Policy.capacity_available?(GiTF.Aramaki.external_active_count())

  defp create_followup(outcome, review, context, head) do
    attrs = %{
      goal: goal(review, context),
      sector_id: Map.get(outcome, :sector_id),
      target_branch: head,
      source: "pr_review",
      source_issue: %{
        "pr_url" => context.url,
        "review_key" => review_key(review),
        "reviewer" => author(review),
        "parent_mission_id" => Map.get(outcome, :mission_id)
      }
    }

    with {:ok, mission} <- Missions.create(attrs),
         :ok <- start(mission) do
      mark_handled(outcome, review)
      Logger.info("PR review intake: #{context.url} → mission #{mission.id} on #{head}")
      {:ok, :mission_created, mission}
    else
      {:error, reason} = err ->
        Logger.warning("PR review intake failed for #{context.url}: #{inspect(reason)}")
        err
    end
  end

  # A created-but-never-started mission sits pending forever: nothing sweeps
  # pending missions into flight except Aramaki's tick, which is default-off.
  defp start(mission) do
    case GiTF.Major.Orchestrator.start_quest(mission.id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  # -- Context adapters ------------------------------------------------------

  defp pr_context(pr) do
    %{
      url: pr["html_url"],
      number: pr["number"],
      title: pr["title"],
      head_ref: get_in(pr, ["head", "ref"])
    }
  end

  # The poller has the outcome record, not a PR payload. The head ref is the
  # mission branch the parent mission pushed, which is what the PR tracks.
  defp poll_context(outcome) do
    %{
      url: Map.get(outcome, :pr_url),
      number: pr_number(Map.get(outcome, :pr_url)),
      title: nil,
      head_ref: parent_branch(outcome)
    }
  end

  defp pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp pr_number(_), do: nil

  defp parent_branch(outcome) do
    with mission_id when is_binary(mission_id) <- Map.get(outcome, :mission_id),
         %{"branch" => branch} when is_binary(branch) <-
           Missions.get_artifact(mission_id, "sync") do
      branch
    else
      _ -> nil
    end
  end

  # -- Goal ------------------------------------------------------------------

  # The reviewer's own words are the specification — restating them in our
  # phrasing is how intent gets lost.
  defp goal(review, context) do
    body = String.trim(body(review) || "")

    feedback =
      if body == "",
        do:
          "The reviewer requested changes without leaving a summary. Read the inline comments on the PR.",
        else: body

    pr_label = if context.number, do: "PR ##{context.number}", else: "the pull request"
    titled = if context.title, do: " (#{context.title})", else: ""

    """
    Address the review feedback on #{pr_label}#{titled}.

    #{author(review) || "A reviewer"} requested changes:

    #{feedback}

    This branch is already open as a pull request. Extend the work that is
    on it — do not revert it or start over. Address every point raised
    above; if a point cannot be addressed, say so explicitly rather than
    silently skipping it.
    """
  end

  # -- Dedupe ----------------------------------------------------------------

  # One key space across both paths. The webhook has a numeric review id and
  # the poller does not, so keying on the id alone would let the same review
  # in twice — once per path — and produce two missions for one piece of
  # feedback. Author plus submission timestamp is available on both.
  defp review_key(review) do
    case {submitted_at(review), Map.get(review, "id") || Map.get(review, :id)} do
      {ts, _} when is_binary(ts) and ts != "" -> "#{author(review) || "?"}@#{ts}"
      # No timestamp: fall back to the id rather than collapsing every review
      # by this author into one key and silently dropping their later
      # feedback. Real payloads from both paths carry submitted_at; this is
      # for malformed ones.
      {_, id} when not is_nil(id) -> "id:#{id}"
      _ -> "#{author(review) || "?"}@?"
    end
  end

  defp handled?(outcome, review) do
    handled = Map.get(outcome, :handled_reviews) || []
    key = review_key(review)
    id = Map.get(review, "id") || Map.get(review, :id)

    key in handled or (not is_nil(id) and id in handled)
  end

  defp mark_handled(outcome, review) do
    id = Map.get(review, "id") || Map.get(review, :id)
    new_keys = Enum.reject([review_key(review), id], &is_nil/1)

    Outcomes.update(outcome.id, fn o ->
      handled = Map.get(o, :handled_reviews) || []
      Map.put(o, :handled_reviews, Enum.uniq(new_keys ++ handled))
    end)
  end

  # -- Field access across both shapes ---------------------------------------

  defp changes_requested?(review), do: Policy.admit_review?(review) != {:reject, :not_changes_requested}

  defp author(review) do
    case Map.get(review, "user") do
      %{"login" => login} -> login
      _ -> Map.get(review, "author") || Map.get(review, :author)
    end
  end

  defp body(review), do: Map.get(review, "body") || Map.get(review, :body)

  defp submitted_at(review),
    do: Map.get(review, "submitted_at") || Map.get(review, :submitted_at)

  defp bot_login do
    Application.get_env(:gitf, :aramaki, []) |> Keyword.get(:bot_login)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:ignored, reason}
end
