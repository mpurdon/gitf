defmodule GiTF.Major.PhasePromptsTest do
  use ExUnit.Case, async: true

  alias GiTF.Major.PhasePrompts

  @mission %{id: "q-1", goal: "Add user authentication", sector_id: "sec-1"}

  describe "triage_prompt/2" do
    test "includes mission goal and sector path" do
      prompt = PhasePrompts.triage_prompt(@mission, %{path: "/code"})
      assert prompt =~ "Add user authentication"
      assert prompt =~ "/code"
      assert prompt =~ "Triage Phase"
    end

    test "handles nil sector with sentinel path" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ "Add user authentication"
    end

    test "declares the complexity buckets" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ "trivial"
      assert prompt =~ "simple"
      assert prompt =~ "moderate"
      assert prompt =~ "complex"
    end

    test "declares the skip_flags schema" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ "skip_research"
      assert prompt =~ "skip_requirements"
      assert prompt =~ "skip_design"
      assert prompt =~ "skip_review"
      assert prompt =~ "skip_planning"
    end

    test "includes time budget and JSON output fence" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ ~r/90 seconds/
      assert prompt =~ "```json"
    end

    test "notes that validation is never skipped" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ ~r/[Vv]alidation.*(?:always|safety)/s
    end

    test "declares the bug_reproducible preflight output field" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ "bug_reproducible"
      assert prompt =~ "bug_evidence"
      assert prompt =~ ~r/[Pp]reflight/
    end

    test "preflight enforces evidence-first ordering (write evidence before flag)" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ ~r/evidence first|evidence.*then flag|IN ORDER/i
      assert prompt =~ ~r/Do NOT set `?bug_reproducible`? before/i
    end

    test "preflight forbids empty bug_evidence" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ ~r/empty.*forbidden|forbidden.*empty|DO NOT emit/i
    end

    test "prompts for case-insensitive grep to catch typo'd casing in bug titles" do
      prompt = PhasePrompts.triage_prompt(@mission, nil)
      assert prompt =~ ~r/case-insensitive|grep -i/
    end

    test "extracts GitHub issue URL into fetch instructions" do
      mission = %{
        id: "q-2",
        goal: "Fix bug at https://github.com/owner/repo/issues/42",
        sector_id: "sec-1"
      }

      prompt = PhasePrompts.triage_prompt(mission, nil)
      assert prompt =~ "gh issue view 42 --repo owner/repo"
    end
  end

  describe "research_prompt/2" do
    test "includes mission goal" do
      prompt = PhasePrompts.research_prompt(@mission, %{path: "/code"})
      assert prompt =~ "Add user authentication"
      assert prompt =~ "/code"
    end

    test "handles nil sector" do
      prompt = PhasePrompts.research_prompt(@mission, nil)
      assert prompt =~ "Add user authentication"
      assert prompt =~ "."
    end

    test "no complexity hint emits the comprehensive prompt" do
      prompt = PhasePrompts.research_prompt(@mission, nil)
      assert prompt =~ "```json"
      assert prompt =~ "architecture"
      assert prompt =~ "key_files"
      assert prompt =~ "tech_stack"
      refute prompt =~ "lightweight"
    end

    test "complex complexity hint emits the comprehensive prompt" do
      prompt = PhasePrompts.research_prompt(@mission, nil, "", complexity: "complex")
      assert prompt =~ "architecture"
      assert prompt =~ "tech_stack"
      refute prompt =~ "lightweight"
    end

    test "simple complexity hint emits the lightweight prompt" do
      prompt = PhasePrompts.research_prompt(@mission, nil, "", complexity: "simple")
      assert prompt =~ "lightweight"
      assert prompt =~ ~r/60 seconds/
      assert prompt =~ "key_files"
      refute prompt =~ "tech_stack"
      refute prompt =~ "architecture"
    end

    test "trivial complexity hint emits the lightweight prompt" do
      prompt = PhasePrompts.research_prompt(@mission, nil, "", complexity: "trivial")
      assert prompt =~ "lightweight"
    end

    test "moderate complexity hint emits the lightweight prompt" do
      prompt = PhasePrompts.research_prompt(@mission, nil, "", complexity: "moderate")
      assert prompt =~ "lightweight"
    end
  end

  describe "requirements_prompt/2" do
    test "includes mission goal and research context" do
      research = %{"architecture" => "MVC", "key_files" => ["app.ex"]}
      prompt = PhasePrompts.requirements_prompt(@mission, research)

      assert prompt =~ "Add user authentication"
      assert prompt =~ "MVC"
      assert prompt =~ "functional_requirements"
    end
  end

  describe "design_prompt/3" do
    test "includes requirements and research" do
      requirements = %{"functional_requirements" => []}
      research = %{"tech_stack" => ["Elixir"]}
      prompt = PhasePrompts.design_prompt(@mission, requirements, research)

      assert prompt =~ "Add user authentication"
      assert prompt =~ "components"
      assert prompt =~ "requirement_mapping"
    end
  end

  describe "design_prompt_with_feedback/4" do
    test "appends review feedback" do
      requirements = %{"functional_requirements" => []}
      research = %{"tech_stack" => []}
      review = %{"approved" => false, "issues" => [%{"description" => "Missing auth flow"}]}

      prompt = PhasePrompts.design_prompt_with_feedback(@mission, requirements, research, review)
      assert prompt =~ "Previous Review Feedback"
      assert prompt =~ "Missing auth flow"
    end
  end

  describe "review_prompt/4" do
    test "includes design, requirements, and research" do
      design = %{"components" => []}
      requirements = %{"functional_requirements" => []}
      research = %{"tech_stack" => []}

      prompt = PhasePrompts.review_prompt(@mission, design, requirements, research)
      assert prompt =~ "Design Review"
      assert prompt =~ "approved"
      assert prompt =~ "coverage"
    end
  end

  describe "planning_prompt/4" do
    test "produces planning instructions with op format" do
      design = %{"components" => []}
      requirements = %{"functional_requirements" => []}
      review = %{"approved" => true}

      prompt = PhasePrompts.planning_prompt(@mission, design, requirements, review)
      assert prompt =~ "Planning Phase"
      assert prompt =~ "depends_on_indices"
      assert prompt =~ "model_recommendation"
    end
  end

  describe "validation_prompt/3" do
    test "includes requirements and planning" do
      requirements = %{"functional_requirements" => [%{"id" => "FR-1"}]}
      planning = [%{"title" => "Implement feature", "target_files" => ["lib/foo.ex"]}]

      prompt = PhasePrompts.validation_prompt(@mission, requirements, planning)
      assert prompt =~ "Validation Phase"
      assert prompt =~ "requirements_met"
      assert prompt =~ "overall_verdict"
      assert prompt =~ "FR-1"
      assert prompt =~ "Implement feature"
    end
  end
end
