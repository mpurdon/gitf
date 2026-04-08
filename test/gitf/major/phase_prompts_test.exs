defmodule GiTF.Major.PhasePromptsTest do
  use ExUnit.Case, async: true

  alias GiTF.Major.PhasePrompts

  @mission %{id: "q-1", goal: "Add user authentication", sector_id: "sec-1"}

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

    test "includes JSON output format instructions" do
      prompt = PhasePrompts.research_prompt(@mission, nil)
      assert prompt =~ "```json"
      assert prompt =~ "architecture"
      assert prompt =~ "key_files"
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
