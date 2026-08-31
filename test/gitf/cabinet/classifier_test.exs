defmodule GiTF.Cabinet.ClassifierTest do
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Classifier

  defp issue(title, labels, action \\ "opened") do
    %{
      "action" => action,
      "issue" => %{"title" => title, "labels" => Enum.map(labels, &%{"name" => &1})}
    }
  end

  test "a bug-labeled issue is a bug" do
    assert Classifier.classify("issues", issue("thing is wrong", ["Bug"])) == :bug
  end

  test "a bug-worded title is a bug even unlabeled" do
    assert Classifier.classify("issues", issue("App crashes on save", [])) == :bug
  end

  test "an unlabeled request is a feature — the queue direction" do
    assert Classifier.classify("issues", issue("Add dark mode", [])) == :feature
  end

  test "issue closes are noise" do
    assert Classifier.classify("issues", %{"action" => "closed"}) == :noise
  end

  test "review feedback is pr_review" do
    assert Classifier.classify("pull_request_review", %{}) == :pr_review
    assert Classifier.classify("issue_comment", %{}) == :pr_review
  end

  test "CI chatter and unknown events never wake anything" do
    assert Classifier.classify("check_suite", %{}) == :ci
    assert Classifier.classify("push", %{}) == :noise
    assert Classifier.classify("wat", nil) == :noise
  end
end
