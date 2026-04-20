defmodule GiTF.Major.OrchestratorTriageRoutingTest do
  @moduledoc """
  Unit tests for the pure triage routing logic:
  `Orchestrator.next_phase_after_triage/1` and
  `Orchestrator.pipeline_mode_for_complexity/1`.

  These are the decision primitives that drive M1's phase-skip behavior.
  Side-effecting phase starters are tested separately via integration tests;
  here we assert the routing decision in isolation.
  """
  use ExUnit.Case, async: true

  alias GiTF.Major.Orchestrator
  alias GiTF.Major.Orchestrator.Decisions

  describe "next_phase_after_triage/1" do
    test "empty skip_flags routes to research (full pipeline)" do
      assert :research = Decisions.next_phase_after_triage(%{})
    end

    test "skip_flags all false routes to research" do
      flags = %{
        "skip_research" => false,
        "skip_requirements" => false,
        "skip_design" => false,
        "skip_review" => false,
        "skip_planning" => false
      }

      assert :research = Decisions.next_phase_after_triage(flags)
    end

    test "only skip_research routes to requirements" do
      assert :requirements = Decisions.next_phase_after_triage(%{"skip_research" => true})
    end

    test "skip_research + skip_requirements routes to design" do
      flags = %{"skip_research" => true, "skip_requirements" => true}
      assert :design = Decisions.next_phase_after_triage(flags)
    end

    test "skip up through skip_review routes to planning" do
      flags = %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true,
        "skip_review" => true
      }

      assert :planning = Decisions.next_phase_after_triage(flags)
    end

    test "all skips set routes to implementation (trivial path)" do
      flags = %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true,
        "skip_review" => true,
        "skip_planning" => true
      }

      assert :implementation = Decisions.next_phase_after_triage(flags)
    end

    test "non-monotonic skips are tolerated — first unskipped phase wins" do
      # The triage prompt's default policy is monotonic, but a misbehaving
      # LLM could emit non-monotonic flags. We still deterministically pick
      # the first unskipped phase in pipeline order.
      flags = %{
        "skip_research" => true,
        "skip_requirements" => false,
        "skip_design" => true,
        "skip_review" => true,
        "skip_planning" => true
      }

      assert :requirements = Decisions.next_phase_after_triage(flags)
    end

    test "non-boolean skip values are treated as not-skipped" do
      # Defensive: if the LLM emits "true" (string) or 1 or nil, we do NOT
      # skip. Skipping on truthy values would let ambiguous output collapse
      # the pipeline silently.
      flags = %{"skip_research" => "true"}
      assert :research = Decisions.next_phase_after_triage(flags)

      flags = %{"skip_research" => nil}
      assert :research = Decisions.next_phase_after_triage(flags)

      flags = %{"skip_research" => 1}
      assert :research = Decisions.next_phase_after_triage(flags)
    end
  end

  describe "pipeline_mode_for_complexity/1" do
    test ":complex → full" do
      assert "full" = Decisions.pipeline_mode_for_complexity(:complex)
    end

    test ":trivial/:simple/:moderate → fast" do
      assert "fast" = Decisions.pipeline_mode_for_complexity(:trivial)
      assert "fast" = Decisions.pipeline_mode_for_complexity(:simple)
      assert "fast" = Decisions.pipeline_mode_for_complexity(:moderate)
    end

    test "unknown values fall back to fast" do
      # Defensive default: unexpected input should take the streamlined
      # pipeline. Validation is still the safety net.
      assert "fast" = Decisions.pipeline_mode_for_complexity(:unknown)
      assert "fast" = Decisions.pipeline_mode_for_complexity(nil)
      assert "fast" = Decisions.pipeline_mode_for_complexity("string_value")
    end
  end

  describe "phases/0" do
    test "triage is the first phase" do
      assert "triage" = List.first(Orchestrator.phases())
    end

    test "triage precedes research" do
      phases = Orchestrator.phases()
      assert Enum.find_index(phases, &(&1 == "triage")) <
               Enum.find_index(phases, &(&1 == "research"))
    end
  end
end
