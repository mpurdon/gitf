defmodule GiTF.Cabinet.Classifier do
  @moduledoc """
  GitHub event → activation class. Deliberately conservative: the only
  classes that can WAKE a box are the ones a human clearly caused (a bug
  report, review feedback on a factory PR). Anything ambiguous is
  `:feature` (queues) or `:noise` (drops) — the failure direction is the
  operator's attention, never silent spend.
  """

  @bug_labels ~w(bug defect regression fix)

  @doc "Classifies `{github_event_header, payload}` into bug | feature | pr_review | ci | noise."
  def classify(event, payload)

  def classify("issues", %{"action" => action} = payload)
      when action in ["opened", "labeled", "reopened"] do
    labels =
      payload
      |> get_in(["issue", "labels"])
      |> List.wrap()
      |> Enum.map(&String.downcase(to_string(&1["name"] || "")))

    title = payload |> get_in(["issue", "title"]) |> to_string() |> String.downcase()

    if Enum.any?(labels, &(&1 in @bug_labels)) or
         title =~ ~r/\b(bug|broken|crash|crashes|crashed|crashing|error|errors|regression)\b/ do
      :bug
    else
      :feature
    end
  end

  def classify("issues", _), do: :noise

  def classify(event, _payload)
      when event in ["pull_request_review", "pull_request_review_comment"],
      do: :pr_review

  # A merged pull request is PR lifecycle the factory owes a response to:
  # record the outcome, close the issue that prompted it, feed the
  # learning loop — while it is fresh, not at whatever wake comes next.
  # A PR closed WITHOUT merging is not worth a wake; the next wake's poll
  # records it.
  def classify("pull_request", %{"action" => "closed", "pull_request" => %{"merged" => true}}),
    do: :pr_review

  # An issue_comment is a PR review only when the issue IS a pull request.
  # A comment on a plain issue — Aramaki's own "picked this up", say — woke
  # the factory it had just been posted from (cora#23, 2026-09-09).
  def classify("issue_comment", payload) do
    if is_map(get_in(payload, ["issue", "pull_request"])), do: :pr_review, else: :noise
  end

  def classify(event, _) when event in ["check_suite", "check_run", "status", "workflow_run"],
    do: :ci

  def classify(_, _), do: :noise
end
