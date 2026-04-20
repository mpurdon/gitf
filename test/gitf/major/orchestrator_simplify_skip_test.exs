defmodule GiTF.Major.OrchestratorSimplifySkipTest do
  @moduledoc """
  Tests for M3's `Decisions.simplify_skippable?/1` — when triage classified
  the mission as trivial or simple, the simplify phase is elided (3 parallel
  review ghosts would be ~2-3 min of wall clock for a change too small to
  benefit from them). Scoring still runs so the learning loop keeps signal.
  """
  use ExUnit.Case, async: true

  alias GiTF.Major.Orchestrator.Decisions

  test "returns true for :trivial" do
    assert Decisions.simplify_skippable?(:trivial)
  end

  test "returns true for :simple" do
    assert Decisions.simplify_skippable?(:simple)
  end

  test "returns false for :moderate" do
    refute Decisions.simplify_skippable?(:moderate)
  end

  test "returns false for :complex" do
    refute Decisions.simplify_skippable?(:complex)
  end

  test "returns false for nil (no triage artifact)" do
    refute Decisions.simplify_skippable?(nil)
  end

  test "returns false for unknown atom (defensive default)" do
    refute Decisions.simplify_skippable?(:unknown)
  end
end
