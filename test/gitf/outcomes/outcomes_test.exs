defmodule GiTF.OutcomesTest do
  use ExUnit.Case, async: false

  alias GiTF.Outcomes

  setup do
    # Ensure feature flag is on for this module
    prior = Application.get_env(:gitf, :outcomes_enabled, false)
    Application.put_env(:gitf, :outcomes_enabled, true)

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    on_exit(fn -> Application.put_env(:gitf, :outcomes_enabled, prior) end)
    :ok
  end

  defp mission(id \\ "msn-abc123"), do: %{id: id, sector_id: "sec-demo1"}

  describe "start_tracking/2" do
    test "creates an outcome record for a new mission" do
      assert {:ok, o} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      assert o.id =~ ~r/^out-/
      assert o.mission_id == "msn-abc123"
      assert o.pr_url == "https://github.com/x/y/pull/1"
      assert o.outcome_category == :pending
      assert o.tracking_stopped == false
      assert o.pr_state == "open"
      assert o.next_poll_at != nil
    end

    test "skips when pr_url is blank" do
      assert Outcomes.start_tracking(mission(), nil) == :skip
      assert Outcomes.start_tracking(mission(), "") == :skip
    end

    test "no-op when :outcomes_enabled is false" do
      Application.put_env(:gitf, :outcomes_enabled, false)
      assert Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1") == :skip
    end

    test "returns existing record instead of duplicating" do
      {:ok, first} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      {:ok, again} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      assert first.id == again.id
    end
  end

  describe "get_for_mission/1 + list_open/0" do
    test "round-trips the record" do
      {:ok, o} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      assert Outcomes.get_for_mission("msn-abc123").id == o.id
      assert Outcomes.get(o.id).id == o.id
      assert [%{} = listed] = Outcomes.list_open()
      assert listed.id == o.id
    end

    test "list_open excludes stopped records" do
      {:ok, o} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      {:ok, _} = Outcomes.stop_tracking(o.id, "test")
      assert Outcomes.list_open() == []
    end

    test "list_open returns [] when disabled" do
      {:ok, _o} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      Application.put_env(:gitf, :outcomes_enabled, false)
      assert Outcomes.list_open() == []
    end
  end

  describe "stop_tracking/2" do
    test "sets stopped flag + reason, idempotent" do
      {:ok, o} = Outcomes.start_tracking(mission(), "https://github.com/x/y/pull/1")
      assert {:ok, stopped} = Outcomes.stop_tracking(o.id, "closed_unmerged")
      assert stopped.tracking_stopped == true
      assert stopped.stopped_reason == "closed_unmerged"
      assert stopped.next_poll_at == nil

      # Second call is a no-op (reason unchanged)
      assert {:ok, again} = Outcomes.stop_tracking(o.id, "other")
      assert again.stopped_reason == "closed_unmerged"
    end
  end

  describe "terminal?/1" do
    test "terminal set" do
      assert Outcomes.terminal?(:merged_clean)
      assert Outcomes.terminal?(:merged_reverted)
      assert Outcomes.terminal?(:closed_unmerged)
      assert Outcomes.terminal?(:merged_broke_main)
      refute Outcomes.terminal?(:pending)
      refute Outcomes.terminal?(:changes_requested)
      refute Outcomes.terminal?(:stale)
    end
  end
end
