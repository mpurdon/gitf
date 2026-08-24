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

    test "skipping design without skipping review does not route to review" do
      # Regression: msn-9b4375. Triage skipped design and left skip_review
      # unset, so routing sent the mission to a review ghost with no design
      # artifact to read. It rejected the empty design, which spent one of
      # the mission's bounded redesign attempts, and bounced to design —
      # arriving where it should have gone directly, one thinking-tier call
      # poorer.
      flags = %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true
      }

      assert :planning = Decisions.next_phase_after_triage(flags, false)
    end

    test "skipping design routes to review when a design already exists" do
      # The resumed-mission case the guard must not break: design landed on
      # an earlier run, so triage skips it and review has real input.
      flags = %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true
      }

      assert :review = Decisions.next_phase_after_triage(flags, true)
    end

    test "a design that exists cannot conjure a review that was skipped" do
      flags = %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true,
        "skip_review" => true
      }

      assert :planning = Decisions.next_phase_after_triage(flags, true)
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

  describe "forced_pipeline_mode?/1" do
    test "an explicitly forced mode is recognised" do
      # Regression: msn-9b4375 was started with full: true and ran as "fast"
      # because triage overwrote the operator's choice with its own read of
      # complexity. The MCP tool advertised an option it then ignored.
      assert Decisions.forced_pipeline_mode?(%{pipeline_mode: "full", pipeline_mode_forced: true})
      assert Decisions.forced_pipeline_mode?(%{pipeline_mode: "fast", pipeline_mode_forced: true})
    end

    test "a mode that merely happens to be full is still inferable" do
      # start_quest writes "full" whenever the fast path wasn't eligible,
      # which is not the same as the operator asking for it.
      refute Decisions.forced_pipeline_mode?(%{pipeline_mode: "full"})
    end

    test "forcing full drops triage's skip flags" do
      # Otherwise --full buys three design strategies only when triage
      # happened to route through design, which for a small change it does
      # not — and the operator who asked for the full pipeline gets a single
      # variant and no comparison to read.
      mission = %{pipeline_mode: "full", pipeline_mode_forced: true}
      flags = %{"skip_research" => true, "skip_design" => true}

      assert %{} == Decisions.effective_skip_flags(mission, flags)
      assert :research = Decisions.next_phase_after_triage(%{}, false)
    end

    test "forcing fast keeps them — skipping is what it asks for" do
      mission = %{pipeline_mode: "fast", pipeline_mode_forced: true}
      flags = %{"skip_research" => true}

      assert ^flags = Decisions.effective_skip_flags(mission, flags)
    end

    test "an unforced mission keeps triage's skip flags" do
      flags = %{"skip_research" => true}

      assert ^flags = Decisions.effective_skip_flags(%{pipeline_mode: "full"}, flags)
      assert ^flags = Decisions.effective_skip_flags(%{}, flags)
    end

    test "forced_pipeline_mode? only trusts a literal true" do
      refute Decisions.forced_pipeline_mode?(%{})
      refute Decisions.forced_pipeline_mode?(%{pipeline_mode_forced: false})
      refute Decisions.forced_pipeline_mode?(%{pipeline_mode_forced: "true"})
      assert Decisions.forced_pipeline_mode?(%{pipeline_mode_forced: true})
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
