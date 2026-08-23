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

  # A review whose mission never landed is not "handled". Releasing it lets
  # the poller try again — but a review that fails forever would loop
  # forever, so each one gets a small, finite number of attempts.
  @max_attempts 3

  @doc """
  Releases a review whose follow-up mission ended without landing.

  Called from the terminal path: feedback is only handled when work actually
  reached the branch. Without this a killed or failed run consumed the
  reviewer's request permanently and the only recovery was editing the store
  by hand.
  """
  @spec release(map()) :: :ok
  def release(mission) do
    with src when is_map(src) <- Map.get(mission, :source_issue),
         url when is_binary(url) <- src["pr_url"],
         key when is_binary(key) <- src["review_key"],
         outcome when is_map(outcome) <- Outcomes.get_by_pr_url(url) do
      drop = Enum.reject([key, src["review_id"]], &is_nil/1)

      Outcomes.update(outcome.id, fn o ->
        attempts = Map.get(o, :review_attempts) || %{}
        n = Map.get(attempts, key, 0) + 1

        o
        |> Map.put(:review_attempts, Map.put(attempts, key, n))
        |> Map.put(
          :handled_reviews,
          # Past the limit it stays handled: retrying a request that has
          # failed three times just burns the factory on a loop.
          if(n >= @max_attempts,
            do: Map.get(o, :handled_reviews) || [],
            else: Enum.reject(Map.get(o, :handled_reviews) || [], &(&1 in drop))
          )
        )
      end)

      Logger.info("PR review released for retry: #{url} (#{key})")
      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug("Review release failed: #{Exception.message(e)}")
      :ok
  end

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
         :ok <- check(attempts(outcome, review) < @max_attempts, :retry_limit_reached),
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
    inline = inline_comments(outcome, context, review)
    body = String.trim(body(review) || "")

    # No summary and no reachable inline comments means there is nothing to
    # act on. Spawning a mission anyway burns a run to discover that, and
    # marking it handled would bury the feedback for good — so leave it
    # unhandled and let a later poll retry once the comments are visible.
    if body == "" and inline == [] do
      {:ok, :ignored, :no_actionable_content}
    else
      do_create(outcome, review, context, head, inline)
    end
  end

  defp do_create(outcome, review, context, head, inline) do
    attrs = %{
      goal: goal(review, context, inline),
      sector_id: Map.get(outcome, :sector_id),
      target_branch: head,
      source: "pr_review",
      source_issue: %{
        "pr_url" => context.url,
        "review_key" => review_key(review),
        # Both keys are written to handled_reviews, so both must be cleared
        # on release — dropping only one leaves the review still "handled".
        "review_id" => Map.get(review, "id") || Map.get(review, :id),
        "reviewer" => author(review),
        "inline_comments" => length(inline),
        # Thread ids, so the completion reply lands under the comments it
        # answers rather than as a top-level comment nobody notices.
        "inline_comment_ids" => Enum.map(inline, & &1.id) |> Enum.reject(&is_nil/1),
        "pr_number" => context.number,
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
      # GitHub is authoritative for the head branch; the sync artifact is a
      # fallback for records predating it. A review fix belongs on the PR it
      # came from — never on a branch of our own choosing.
      head_ref: Map.get(outcome, :pr_head_ref) || parent_branch(outcome)
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
  #
  # Requesting changes through a `suggestion` block leaves the review body
  # EMPTY and puts the whole ask in an inline comment, which is the ordinary
  # way people review. Reading only the body produced a mission told to "read
  # the inline comments" with no means to do so.
  defp goal(review, context, inline) do
    body = String.trim(body(review) || "")
    pr_label = if context.number, do: "PR ##{context.number}", else: "the pull request"
    titled = if context.title, do: " (#{context.title})", else: ""

    summary =
      if body == "", do: "", else: "\n#{author(review) || "A reviewer"} wrote:\n\n#{body}\n"

    """
    Address the review feedback on #{pr_label}#{titled}.
    #{summary}#{inline_section(inline)}
    This branch is already open as a pull request. Extend the work that is
    on it — do not revert it or start over. Address every point raised
    above; if a point cannot be addressed, say so explicitly rather than
    silently skipping it.
    """
  end

  defp inline_section([]), do: ""

  defp inline_section(comments) do
    rendered =
      comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {c, i} ->
        where = "#{c.path}#{if c.line, do: ":#{c.line}", else: ""}"
        "### #{i}. #{where}\n\n#{String.trim(c.body || "")}"
      end)

    """

    ## Inline comments (#{length(comments)})

    Each is anchored to a file and line. A fenced ```suggestion block is the
    reviewer's exact replacement text for the lines it is attached to —
    apply it verbatim unless it is plainly wrong, in which case explain why.

    #{rendered}
    """
  end

  # Comments belonging to this review when the API gives us the linkage;
  # otherwise every inline comment by the same author, since an unattributed
  # comment from the reviewer is still outstanding feedback. Failure to fetch
  # is not fatal — a mission with the body alone beats no mission.
  defp inline_comments(outcome, context, review) do
    review_id = Map.get(review, "id") || Map.get(review, :id)

    with sector_id when is_binary(sector_id) <- Map.get(outcome, :sector_id),
         {:ok, sector} <- GiTF.Sector.get(sector_id),
         number when is_integer(number) <- normalize_number(context.number),
         {:ok, comments} <- GiTF.GitHub.list_review_comments(sector, number) do
      scoped =
        case Enum.filter(comments, &(&1.review_id == review_id)) do
          [] -> Enum.filter(comments, &(&1.author == author(review)))
          matched -> matched
        end

      Enum.take(scoped, 25)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp normalize_number(n) when is_integer(n), do: n

  defp normalize_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

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

  defp attempts(outcome, review) do
    (Map.get(outcome, :review_attempts) || %{}) |> Map.get(review_key(review), 0)
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
