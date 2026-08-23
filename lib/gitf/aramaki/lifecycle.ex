defmodule GiTF.Aramaki.Lifecycle do
  @moduledoc """
  Reports a mission's progress back onto whatever prompted it — a GitHub
  issue, or the pull request whose review asked for changes.

  Outbound GitHub communication lives here for the same reason admission
  does: the factory has one boundary with the outside world, and spreading
  "tell the human what happened" across whichever module happens to finish
  the work is how half the paths end up silent. Acting on review feedback
  without acknowledging it is worse than not acting — the reviewer sees
  commits appear with no way to tell whether they answered the review.

  All calls are best-effort and no-op unless the mission carries a usable
  source linkage and the sector has GitHub credentials. Every comment is
  signed so the factory can recognise (and ignore) its own activity — loop
  prevention lives in `Aramaki.Policy.admit_issue?/2` and `admit_review?/2`.
  """

  require Logger

  @signature "\n\n_— posted by the GiTF Dark Factory (Aramaki)_"

  @doc "Mission admitted → acknowledge on the issue and mark it in progress."
  @spec on_admitted(map()) :: :ok
  def on_admitted(mission) do
    with_issue(mission, fn sector, num ->
      GiTF.GitHub.add_label(sector, num, "gitf:in-progress")

      comment(
        sector,
        num,
        "Aramaki picked this up. Mission `#{mission.id}` is now running." <> @signature
      )
    end)
  end

  @doc "Mission published a PR → link it on the issue."
  @spec on_published(map(), String.t()) :: :ok
  def on_published(mission, pr_url) do
    with_issue(mission, fn sector, num ->
      comment(sector, num, "Opened a pull request for this: #{pr_url}" <> @signature)
    end)
  end

  @doc "Mission merged → close the issue."
  @spec on_merged(map()) :: :ok
  def on_merged(mission) do
    with_issue(mission, fn sector, num ->
      comment(sector, num, "Merged — closing this issue." <> @signature)
      GiTF.GitHub.add_label(sector, num, "gitf:done")
      GiTF.GitHub.close_issue(sector, num)
    end)
  end

  @doc "Mission failed → report the reason (issue stays open for a human)."
  @spec on_failed(map(), String.t()) :: :ok
  def on_failed(mission, reason) do
    with_issue(mission, fn sector, num ->
      comment(
        sector,
        num,
        "Mission `#{mission.id}` could not complete this: #{String.slice(reason, 0, 300)}. " <>
          "Leaving the issue open for a human." <> @signature
      )
    end)
  end

  @doc """
  A review-driven follow-up finished → say so on the pull request.

  Deliberately does not claim each point was addressed: the factory has no
  per-comment mapping, and a confident "all feedback addressed" that is
  wrong is worse than an honest pointer. It states what it responded to and
  where to look, and leaves the judgement — and the Resolve button — with
  the reviewer.
  """
  @spec on_review_addressed(map()) :: :ok
  def on_review_addressed(mission) do
    with_pr(mission, fn sector, num, src ->
      body =
        "Pushed changes in response to this. Mission `#{mission.id}` committed to the branch — " <>
          "the diff is the response.\n\nRe-review rather than assuming this point is settled: " <>
          "the factory answers a review as a whole and cannot prove which individual comment a " <>
          "given change resolves." <> @signature

      answer_threads(sector, num, src, body, fn ->
        reviewer = src["reviewer"]
        who = if reviewer, do: "@#{reviewer}'s", else: "the"

        "Pushed changes in response to #{who} review request. Mission `#{mission.id}` " <>
          "committed to this branch — the diff above is the response. Please re-review." <>
          @signature
      end)
    end)
  end

  @doc "A review-driven follow-up failed → say that too, rather than going quiet."
  @spec on_review_failed(map(), String.t()) :: :ok
  def on_review_failed(mission, reason) do
    with_pr(mission, fn sector, num, src ->
      reviewer = src["reviewer"]
      who = if reviewer, do: "@#{reviewer}", else: "the reviewer"

      # Never claim nothing was pushed: a mission can do the work correctly
      # and then fail a later phase. msn-dd29a1 committed the requested
      # one-line fix and failed at validation, and this comment told the
      # reviewer their branch was untouched — a confident falsehood, which is
      # worse than silence. State only what is known: the run did not finish.
      body =
        "Mission `#{mission.id}` did not complete this review request — " <>
          "#{String.slice(reason, 0, 300)}.\n\n" <>
          "Check the branch before assuming nothing changed: work may have been " <>
          "committed before the run stopped. The request stands until you resolve it." <>
          @signature

      answer_threads(sector, num, src, body, fn ->
        "#{who}: mission `#{mission.id}` did not complete this review request — " <>
          "#{String.slice(reason, 0, 300)}.\n\nCheck the branch before assuming nothing " <>
          "changed. The request stands." <> @signature
      end)
    end)
  end

  # Reply inside each thread the mission was answering, so the response sits
  # under the reviewer's own words and the conversation can be resolved. A
  # top-level PR comment is the fallback for a review that left no inline
  # comments — and it is what the reviewer missed entirely last time.
  defp answer_threads(sector, num, src, thread_body, fallback_fun) do
    ids = List.wrap(src["inline_comment_ids"]) |> Enum.filter(&is_integer/1)

    replied =
      Enum.count(ids, fn id ->
        GiTF.GitHub.reply_to_review_comment(sector, num, id, thread_body) == :ok
      end)

    # Nothing to reply to, or every reply failed: say it once on the PR
    # rather than saying nothing at all.
    if replied == 0, do: comment(sector, num, fallback_fun.())
    :ok
  end

  # -- Internals -------------------------------------------------------------

  # PR-review missions carry a pr_url rather than the {number, repo} pair an
  # issue-sourced mission has, so the owner/repo/number are parsed back out.
  # GitHub's issue-comments endpoint serves pull requests too, which is why
  # add_comment/3 works unchanged here.
  defp with_pr(mission, fun) do
    with src when is_map(src) <- Map.get(mission, :source_issue),
         url when is_binary(url) <- src["pr_url"] || src[:pr_url],
         [_, owner, repo, num] <-
           Regex.run(~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}, url),
         {:ok, sector} <- GiTF.Sector.by_github("#{owner}/#{repo}"),
         {number, _} <- Integer.parse(num) do
      fun.(sector, number, src)
      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug("Aramaki.Lifecycle PR side-effect failed: #{Exception.message(e)}")
      :ok
  end

  defp with_issue(mission, fun) do
    with %{number: num, repo: repo} when is_integer(num) <- Map.get(mission, :source_issue),
         {:ok, sector} <- GiTF.Sector.by_github(repo) do
      fun.(sector, num)
      :ok
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.debug("Aramaki.Lifecycle side-effect failed: #{Exception.message(e)}")
      :ok
  end

  defp comment(sector, num, body) do
    GiTF.GitHub.add_comment(sector, num, body)
  rescue
    _ -> :ok
  end
end
