defmodule GiTF.Outcomes.EventsPollerTest do
  @moduledoc """
  The events poller exists for exactly one scenario: activity landing on a
  factory PR after the Tracker stopped looking (72h staleness, or a long
  idle-stop). It must revive precisely those records — and must NOT revive
  on events we have already seen, or the 30-day feed would resurrect every
  stale record on every boot.
  """

  use ExUnit.Case, async: false

  alias GiTF.Outcomes
  alias GiTF.Outcomes.EventsPoller

  setup do
    prior = Application.get_env(:gitf, :outcomes_enabled, false)
    GiTF.Test.StoreHelper.restore_app_store()

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    on_exit(fn -> Application.put_env(:gitf, :outcomes_enabled, prior) end)
    :ok
  end

  defp dt(iso), do: elem(DateTime.from_iso8601(iso), 1)

  defp event(type, url, created_at) do
    %{
      "type" => type,
      "created_at" => created_at,
      "payload" => %{"pull_request" => %{"html_url" => url}}
    }
  end

  describe "pr_activity/1" do
    test "keeps PR and review events, drops everything else" do
      events = [
        event("PullRequestEvent", "https://github.com/o/r/pull/5", "2026-08-27T10:00:00Z"),
        event("PullRequestReviewEvent", "https://github.com/o/r/pull/6", "2026-08-27T11:00:00Z"),
        event("PushEvent", "https://github.com/o/r/pull/7", "2026-08-27T12:00:00Z"),
        %{"type" => "IssuesEvent", "created_at" => "2026-08-27T12:00:00Z", "payload" => %{}}
      ]

      urls = EventsPoller.pr_activity(events) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert urls == ["https://github.com/o/r/pull/5", "https://github.com/o/r/pull/6"]
    end

    test "collapses to the latest event per PR" do
      events = [
        event("PullRequestEvent", "https://github.com/o/r/pull/5", "2026-08-27T10:00:00Z"),
        event("PullRequestReviewEvent", "https://github.com/o/r/pull/5", "2026-08-27T14:00:00Z"),
        event("PullRequestEvent", "https://github.com/o/r/pull/5", "2026-08-27T12:00:00Z")
      ]

      assert [{"https://github.com/o/r/pull/5", time}] = EventsPoller.pr_activity(events)
      assert time == dt("2026-08-27T14:00:00Z")
    end

    test "tolerates malformed events" do
      events = [
        %{"type" => "PullRequestEvent"},
        %{"type" => "PullRequestEvent", "created_at" => "not-a-date", "payload" => %{}},
        event("PullRequestEvent", "https://github.com/o/r/pull/9", "2026-08-27T10:00:00Z")
      ]

      assert [{"https://github.com/o/r/pull/9", _}] = EventsPoller.pr_activity(events)
    end
  end

  describe "needs_revival?/2" do
    test "true when the event postdates the last poll" do
      outcome = %{last_polled_at: dt("2026-08-26T00:00:00Z")}
      assert EventsPoller.needs_revival?(outcome, dt("2026-08-27T00:00:00Z"))
    end

    test "false for events we already saw — the boot-idempotence guarantee" do
      outcome = %{last_polled_at: dt("2026-08-28T00:00:00Z")}
      refute EventsPoller.needs_revival?(outcome, dt("2026-08-27T00:00:00Z"))
      refute EventsPoller.needs_revival?(outcome, dt("2026-08-28T00:00:00Z"))
    end

    test "falls back to first_tracked_at for never-polled records" do
      outcome = %{last_polled_at: nil, first_tracked_at: dt("2026-08-26T00:00:00Z")}
      assert EventsPoller.needs_revival?(outcome, dt("2026-08-27T00:00:00Z"))
      refute EventsPoller.needs_revival?(outcome, dt("2026-08-25T00:00:00Z"))
    end

    test "revives when the record has no timestamps at all" do
      assert EventsPoller.needs_revival?(%{}, dt("2026-08-27T00:00:00Z"))
    end
  end

  describe "Outcomes.revive/1" do
    test "a 72h-expired record goes back onto the tracker's plate" do
      Application.put_env(:gitf, :outcomes_enabled, true)

      {:ok, outcome} =
        GiTF.Archive.insert(:mission_outcomes, %{
          mission_id: "msn-poller",
          sector_id: "sec-poller",
          pr_url: "https://github.com/o/r/pull/42",
          pr_state: "open",
          outcome_category: :pending,
          first_tracked_at: dt("2026-08-20T00:00:00Z"),
          last_activity_at: dt("2026-08-20T00:00:00Z"),
          last_polled_at: dt("2026-08-23T00:00:00Z"),
          next_poll_at: nil,
          poll_count: 3,
          tracking_stopped: true,
          stopped_reason: "72h expired"
        })

      refute Enum.any?(Outcomes.list_open(), &(&1.id == outcome.id))

      {:ok, revived} = Outcomes.revive(outcome.id)

      refute revived.tracking_stopped
      assert revived.stopped_reason == nil
      assert %DateTime{} = revived.next_poll_at
      # last_activity_at is bumped so Analyzer.stale? doesn't re-stop the
      # record on the very next tick.
      assert DateTime.compare(revived.last_activity_at, dt("2026-08-21T00:00:00Z")) == :gt
      assert Enum.any?(Outcomes.list_open(), &(&1.id == outcome.id))
    end
  end
end
