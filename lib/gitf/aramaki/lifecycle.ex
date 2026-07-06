defmodule GiTF.Aramaki.Lifecycle do
  @moduledoc """
  Reports a mission's progress back onto its source GitHub issue.

  All calls are best-effort and no-op unless the mission actually came from a
  GitHub issue (`:source_issue` set) and the sector has GitHub credentials.
  Every comment is signed so the factory can recognise (and ignore) its own
  activity — loop prevention lives in `Aramaki.Policy.admit_issue?/2`.
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

  # -- Internals -------------------------------------------------------------

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
