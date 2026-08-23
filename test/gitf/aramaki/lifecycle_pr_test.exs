defmodule GiTF.Aramaki.LifecyclePRTest do
  @moduledoc """
  A review-driven mission owes the reviewer an answer either way. These pin
  the source-linkage parsing that decides whether one gets sent — the rest of
  Lifecycle is a GitHub side effect and stays best-effort.
  """
  use GiTF.StoreCase

  alias GiTF.Aramaki.Lifecycle

  defp mission(source_issue),
    do: %{id: "msn-test01", source: "pr_review", source_issue: source_issue}

  test "a mission with no source linkage is silently a no-op" do
    assert Lifecycle.on_review_addressed(mission(nil)) == :ok
    assert Lifecycle.on_review_addressed(%{id: "msn-x"}) == :ok
    assert Lifecycle.on_review_failed(mission(nil), "boom") == :ok
  end

  test "an unparseable pr_url does not raise" do
    for url <- ["not a url", "https://github.com/owner/repo", "https://example.com/pull/8", ""] do
      assert Lifecycle.on_review_addressed(mission(%{"pr_url" => url})) == :ok
    end
  end

  test "a well-formed pr_url for an unknown repo is a no-op, not an error" do
    # No sector matches this repo, so there are no credentials to comment
    # with. Best-effort means silent, never a crash in the completion path.
    assert Lifecycle.on_review_addressed(
             mission(%{"pr_url" => "https://github.com/nobody/nothing/pull/8"})
           ) == :ok
  end

  test "failure reporting is a no-op under the same conditions" do
    assert Lifecycle.on_review_failed(
             mission(%{"pr_url" => "https://github.com/nobody/nothing/pull/8"}),
             "provider down"
           ) == :ok
  end

  test "tolerates missing, empty or malformed thread ids" do
    # answer_threads filters to integers and falls back to a PR comment; a
    # malformed record must never raise inside a completion path.
    for ids <- [nil, [], ["not-an-int"], [123, nil, "x"]] do
      m = mission(%{"pr_url" => "https://github.com/nobody/nothing/pull/8", "inline_comment_ids" => ids})
      assert Lifecycle.on_review_addressed(m) == :ok
      assert Lifecycle.on_review_failed(m, "boom") == :ok
    end
  end
end
