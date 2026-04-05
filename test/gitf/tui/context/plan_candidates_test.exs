defmodule GiTF.TUI.Context.PlanCandidatesTest do
  use ExUnit.Case, async: true

  alias GiTF.TUI.Context.Plan

  describe "load_plan/2 with candidates" do
    test "stores candidates when provided" do
      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: [%{"title" => "Min task"}]},
        %{
          strategy: "balanced",
          score: 0.8,
          tasks: [%{"title" => "Bal task 1"}, %{"title" => "Bal task 2"}]
        },
        %{strategy: "thorough", score: 0.7, tasks: [%{"title" => "Thor task"}]}
      ]

      plan_data = %{
        mission_id: "msn-123",
        goal: "Test goal",
        tasks: [%{"title" => "Task 1"}],
        candidates: candidates
      }

      state = Plan.new() |> Plan.load_plan(plan_data)

      assert state.candidates == candidates
      assert state.candidate_index == 0
      assert state.mode == :reviewing
      assert length(state.sections) == 1
    end

    test "preserves empty candidates when not provided" do
      plan_data = %{
        mission_id: "msn-456",
        goal: "Another goal",
        tasks: [%{"title" => "Task 1"}]
      }

      state = Plan.new() |> Plan.load_plan(plan_data)

      assert state.candidates == []
      assert state.candidate_index == 0
    end
  end

  describe "next_candidate/1" do
    test "cycles through candidates" do
      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: []},
        %{strategy: "balanced", score: 0.8, tasks: []},
        %{strategy: "thorough", score: 0.7, tasks: []}
      ]

      state = %{Plan.new() | candidates: candidates, candidate_index: 0}

      state = Plan.next_candidate(state)
      assert state.candidate_index == 1

      state = Plan.next_candidate(state)
      assert state.candidate_index == 2

      # Wraps around
      state = Plan.next_candidate(state)
      assert state.candidate_index == 0
    end

    test "no-op when no candidates" do
      state = Plan.new()
      assert Plan.next_candidate(state) == state
    end
  end

  describe "candidate_count/1" do
    test "returns length of candidates" do
      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: []},
        %{strategy: "balanced", score: 0.8, tasks: []}
      ]

      state = %{Plan.new() | candidates: candidates}
      assert Plan.candidate_count(state) == 2
    end

    test "returns 0 when empty" do
      assert Plan.candidate_count(Plan.new()) == 0
    end
  end

  describe "current_strategy/1" do
    test "returns strategy and score for current index" do
      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: []},
        %{strategy: "balanced", score: 0.8, tasks: []},
        %{strategy: "thorough", score: 0.7, tasks: []}
      ]

      state = %{Plan.new() | candidates: candidates, candidate_index: 0}
      assert Plan.current_strategy(state) == {"minimal", 0.6}

      state = %{state | candidate_index: 1}
      assert Plan.current_strategy(state) == {"balanced", 0.8}

      state = %{state | candidate_index: 2}
      assert Plan.current_strategy(state) == {"thorough", 0.7}
    end

    test "returns nil when no candidates" do
      assert Plan.current_strategy(Plan.new()) == nil
    end
  end

  describe "dismiss/1" do
    test "resets candidates and index" do
      candidates = [%{strategy: "minimal", score: 0.6, tasks: []}]

      state = %{
        Plan.new()
        | candidates: candidates,
          candidate_index: 1,
          mode: :reviewing,
          mission_id: "msn-123"
      }

      dismissed = Plan.dismiss(state)
      assert dismissed.candidates == []
      assert dismissed.candidate_index == 0
      assert dismissed.mode == :hidden
    end
  end
end
