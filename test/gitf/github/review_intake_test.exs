defmodule GiTF.GitHub.ReviewIntakeTest do
  @moduledoc """
  A webhook can be sent by anyone who knows the URL, so intake's refusals
  matter more than its happy path: it must never spawn work for a PR the
  factory does not already own, and a redelivered event must not queue the
  same work twice.
  """
  use ExUnit.Case, async: false

  alias GiTF.GitHub.ReviewIntake
  alias GiTF.Outcomes

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    prev_intake = Application.get_env(:gitf, :pr_review_intake_enabled)
    prev_outcomes = Application.get_env(:gitf, :outcomes_enabled)
    Application.put_env(:gitf, :pr_review_intake_enabled, true)
    Application.put_env(:gitf, :outcomes_enabled, true)

    on_exit(fn ->
      Application.put_env(:gitf, :pr_review_intake_enabled, prev_intake)
      Application.put_env(:gitf, :outcomes_enabled, prev_outcomes)
    end)

    # The store is shared across tests, so each one needs its own PR or the
    # dedupe state from a previous test bleeds in.
    n = System.unique_integer([:positive])
    {:ok, url: "https://github.com/acme/cora/pull/#{n}", n: n}
  end

  defp tracked_pr(url) do
    {:ok, mission} = GiTF.Missions.create(%{goal: "original work", sector_id: "sec-test"})
    Outcomes.start_tracking(mission, url)
    mission
  end

  defp payload(url, overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "submitted",
        "review" => %{
          "id" => 991,
          "state" => "changes_requested",
          "body" => "The drawer clobbers settings from the other window.",
          "html_url" => "#{url}#pullrequestreview-991",
          "user" => %{"login" => "mpurdon"}
        },
        "pull_request" => %{
          "html_url" => url,
          "number" => 8,
          "title" => "Configurable approve messages",
          "head" => %{"ref" => "mission/msn-ff3fc6-approve-messages"}
        }
      },
      overrides
    )
  end

  defp review(url, changes), do: payload(url)["review"] |> Map.merge(changes)

  test "a changes-requested review on a tracked PR becomes a follow-up mission", ctx do
    parent = tracked_pr(ctx.url)

    assert {:ok, :mission_created, mission} = ReviewIntake.dispatch(payload(ctx.url))

    assert mission.goal =~ "clobbers settings from the other window"
    assert mission.goal =~ "PR #8"
    assert mission.source == "pr_review"
    assert mission.source_issue["parent_mission_id"] == parent.id
    assert mission.sector_id == "sec-test"
  end

  test "the follow-up targets the PR head so the open PR updates in place", ctx do
    tracked_pr(ctx.url)

    assert {:ok, :mission_created, mission} = ReviewIntake.dispatch(payload(ctx.url))
    assert mission.target_branch == "mission/msn-ff3fc6-approve-messages"
  end

  test "a PR the factory never opened is ignored", ctx do
    # No outcome record — nothing links this PR to the factory.
    assert {:ok, :ignored, :untracked_pr} = ReviewIntake.dispatch(payload(ctx.url))
  end

  test "approvals and plain comments do not spawn work", ctx do
    tracked_pr(ctx.url)

    for state <- ["approved", "commented", "APPROVED"] do
      p = payload(ctx.url, %{"review" => review(ctx.url, %{"state" => state})})
      assert {:ok, :ignored, :not_changes_requested} = ReviewIntake.dispatch(p)
    end
  end

  test "an edited or dismissed review is not a fresh request for changes", ctx do
    tracked_pr(ctx.url)

    assert {:ok, :ignored, :not_submitted} =
             ReviewIntake.dispatch(payload(ctx.url, %{"action" => "dismissed"}))
  end

  test "a redelivered webhook does not queue the work twice", ctx do
    tracked_pr(ctx.url)

    assert {:ok, :mission_created, _} = ReviewIntake.dispatch(payload(ctx.url))
    assert {:ok, :ignored, :already_handled} = ReviewIntake.dispatch(payload(ctx.url))
  end

  test "a second, distinct review on the same PR is ingested", ctx do
    tracked_pr(ctx.url)

    assert {:ok, :mission_created, _} = ReviewIntake.dispatch(payload(ctx.url))

    later = review(ctx.url, %{"id" => 992, "body" => "still wrong"})
    assert {:ok, :mission_created, m} = ReviewIntake.dispatch(payload(ctx.url, %{"review" => later}))
    assert m.goal =~ "still wrong"
  end

  test "a changes-requested review with no summary still gives the mission direction", ctx do
    tracked_pr(ctx.url)

    blank = review(ctx.url, %{"body" => "   "})
    assert {:ok, :mission_created, m} = ReviewIntake.dispatch(payload(ctx.url, %{"review" => blank}))
    assert m.goal =~ "inline comments"
  end

  test "does nothing at all when the feature is off", ctx do
    Application.put_env(:gitf, :pr_review_intake_enabled, false)
    tracked_pr(ctx.url)

    assert {:ok, :ignored, :disabled} = ReviewIntake.dispatch(payload(ctx.url))
  end

  test "a malformed payload is ignored rather than crashing the webhook", ctx do
    tracked_pr(ctx.url)

    assert {:ok, :ignored, _} = ReviewIntake.dispatch(%{"action" => "submitted"})
    assert {:ok, :ignored, _} = ReviewIntake.dispatch(payload(ctx.url, %{"pull_request" => %{}}))
  end
end
