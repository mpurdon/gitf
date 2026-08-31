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
      when event in ["pull_request_review", "pull_request_review_comment", "issue_comment"],
      do: :pr_review

  def classify(event, _) when event in ["check_suite", "check_run", "status", "workflow_run"],
    do: :ci

  def classify(_, _), do: :noise
end
