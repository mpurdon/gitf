defmodule Hive.Queen.PhasePrompts do
  @moduledoc """
  Pure functions that build prompts for each orchestration phase.

  Each prompt provides context from prior phases and specifies the exact
  JSON output format expected. Phase bees are instructed to output ONLY
  a JSON object fenced in ```json blocks.
  """

  @doc """
  Builds the research phase prompt.

  Instructs the bee to analyze the codebase and output structured findings.
  """
  @spec research_prompt(map(), map() | nil) :: String.t()
  def research_prompt(quest, comb) do
    comb_path = if comb, do: comb.path, else: "."

    """
    # Research Phase

    You are a codebase analyst. Your task is to thoroughly research and understand the
    codebase to inform the implementation of the following goal:

    **Goal**: #{quest.goal}

    **Codebase location**: #{comb_path}

    ## Instructions

    1. Read key files to understand the project architecture
    2. Identify coding patterns, conventions, and style
    3. Understand the tech stack and dependencies
    4. Identify test setup and testing conventions
    5. Note any risks or constraints relevant to the goal

    ## Output Format

    Output ONLY a JSON object in a ```json fence with this structure:

    ```json
    {
      "architecture": "Brief description of the project architecture",
      "key_files": ["list", "of", "important", "files"],
      "patterns": ["coding patterns and conventions observed"],
      "tech_stack": ["list of technologies and frameworks"],
      "test_setup": "Description of test framework and conventions",
      "dependencies": ["key dependencies relevant to the goal"],
      "risks": ["potential risks or challenges for this goal"]
    }
    ```

    Be thorough but concise. Focus on information relevant to achieving the goal.
    """
  end

  @doc """
  Builds the requirements phase prompt.

  Produces structured requirements with testable acceptance criteria from
  the goal and research findings.
  """
  @spec requirements_prompt(map(), map()) :: String.t()
  def requirements_prompt(quest, research_artifact) do
    research_json = Jason.encode!(research_artifact, pretty: true)

    """
    # Requirements Phase

    You are a requirements analyst. From the goal and codebase research below,
    produce structured requirements with testable acceptance criteria.

    **Goal**: #{quest.goal}

    ## Codebase Research

    ```json
    #{research_json}
    ```

    ## Instructions

    1. Break the goal into specific functional requirements
    2. Each requirement must have testable acceptance criteria
    3. Identify non-functional requirements (performance, security, etc.)
    4. Note constraints from the existing codebase
    5. Explicitly list what is OUT of scope

    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "functional_requirements": [
        {
          "id": "FR-1",
          "description": "Description of the requirement",
          "acceptance_criteria": ["Testable criterion 1", "Testable criterion 2"],
          "priority": "must-have"
        }
      ],
      "non_functional": [
        {
          "id": "NFR-1",
          "description": "Non-functional requirement",
          "acceptance_criteria": ["Testable criterion"]
        }
      ],
      "constraints": ["Constraints from the existing codebase"],
      "out_of_scope": ["Things explicitly not included"]
    }
    ```

    Keep requirements minimal and focused. Do not add unnecessary scope.
    """
  end

  @doc """
  Builds the design phase prompt.

  Maps requirements to implementation approach with specific file changes.
  """
  @spec design_prompt(map(), map(), map(), String.t()) :: String.t()
  def design_prompt(quest, requirements, research, extra_instructions \\ "") do
    requirements_json = Jason.encode!(requirements, pretty: true)
    research_json = Jason.encode!(research, pretty: true)

    instructions = """
    1. Map each requirement to a specific implementation approach
    2. List exact files to create or modify
    3. Define API contracts and interfaces
    4. Identify component dependencies
    5. Note implementation risks
    """

    final_instructions =
      if extra_instructions != "", do: instructions <> "#{extra_instructions}\n", else: instructions

    """
    # Technical Design Phase

    You are a software architect. Design the implementation approach for
    the following requirements, given the codebase research.

    **Goal**: #{quest.goal}

    ## Codebase Research

    ```json
    #{research_json}
    ```

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Instructions

    #{final_instructions}
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "components": [
        {
          "name": "Component name",
          "description": "What this component does",
          "files": ["lib/path/to/file.ex"],
          "interfaces": ["public function signatures or API endpoints"]
        }
      ],
      "requirement_mapping": [
        {
          "req_id": "FR-1",
          "component": "Component name",
          "approach": "How this requirement will be implemented"
        }
      ],
      "dependencies": [
        {
          "from": "Component A",
          "to": "Component B"
        }
      ],
      "risks": ["Implementation risks and mitigations"]
    }
    ```
    """
  end

  @doc """
  Builds the design prompt with review feedback for redesign iterations.
  """
  @spec design_prompt_with_feedback(map(), map(), map(), map(), String.t()) :: String.t()
  def design_prompt_with_feedback(quest, requirements, research, review, extra_instructions \\ "") do
    base = design_prompt(quest, requirements, research, extra_instructions)
    review_json = Jason.encode!(review, pretty: true)

    base <>
      """

      ## IMPORTANT: Previous Review Feedback

      Your previous design was reviewed and issues were found. Address ALL of
      the following feedback in your revised design:

      ```json
      #{review_json}
      ```

      Pay special attention to any coverage gaps or high-severity issues.
      """
  end

  @doc """
  Builds the review phase prompt.

  Cross-validates design against requirements.
  """
  @spec review_prompt(map(), map(), map(), map()) :: String.t()
  def review_prompt(quest, design, requirements, research) do
    design_json = Jason.encode!(design, pretty: true)
    requirements_json = Jason.encode!(requirements, pretty: true)
    research_json = Jason.encode!(research, pretty: true)

    """
    # Design Review Phase

    You are a technical reviewer. Cross-validate the design against the
    requirements. Check for coverage gaps, feasibility issues, and risks.

    **Goal**: #{quest.goal}

    ## Codebase Research

    ```json
    #{research_json}
    ```

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Technical Design

    ```json
    #{design_json}
    ```

    ## Instructions

    1. Verify every functional requirement has a design component
    2. Check that the design is feasible given the codebase architecture
    3. Identify any gaps, inconsistencies, or missing pieces
    4. Assess implementation risks
    5. Approve or reject with specific feedback

    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "approved": true,
      "coverage": [
        {
          "req_id": "FR-1",
          "covered": true,
          "gap": null
        }
      ],
      "issues": [
        {
          "severity": "high",
          "description": "Description of the issue",
          "suggestion": "How to fix it"
        }
      ],
      "risk_assessment": "Overall risk assessment summary"
    }
    ```

    Set `approved` to false if there are any high-severity issues or
    uncovered requirements. Be rigorous but practical.
    """
  end

  @doc """
  Builds the planning phase prompt.

  Generates ordered jobs with dependencies from the validated design.
  """
  @spec planning_prompt(map(), map(), map(), map()) :: String.t()
  def planning_prompt(quest, design, requirements, review) do
    design_json = Jason.encode!(design, pretty: true)
    requirements_json = Jason.encode!(requirements, pretty: true)
    review_json = Jason.encode!(review, pretty: true)

    """
    # Planning Phase

    You are a project planner. From the validated design, produce an ordered
    list of implementation jobs with dependencies.

    **Goal**: #{quest.goal}

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Technical Design

    ```json
    #{design_json}
    ```

    ## Review Feedback

    ```json
    #{review_json}
    ```

    ## Instructions

    1. Break the design into discrete, parallelizable jobs
    2. Each job should be completable by a single developer in one session
    3. Define clear acceptance criteria derived from requirements
    4. Specify target files from the design
    5. Set up dependencies (job indices, 0-based)
    6. Recommend model complexity (sonnet for simple, opus for complex)

    ## Output Format

    Output ONLY a JSON array in a ```json fence:

    ```json
    [
      {
        "title": "Short descriptive title",
        "description": "Detailed implementation instructions",
        "target_files": ["lib/path/to/file.ex"],
        "acceptance_criteria": ["Testable criterion 1", "Testable criterion 2"],
        "depends_on_indices": [],
        "model_recommendation": "sonnet"
      }
    ]
    ```

    Keep the number of jobs minimal. Prefer fewer, larger jobs over many small ones.
    """
  end

  @doc """
  Builds the validation phase prompt.

  Reviews all implementation against original requirements.
  """
  @spec validation_prompt(map(), map()) :: String.t()
  def validation_prompt(quest, all_artifacts) do
    artifacts_json = Jason.encode!(all_artifacts, pretty: true)

    """
    # Validation Phase

    You are a QA validator. Review all implementation work against the
    original requirements and design.

    **Goal**: #{quest.goal}

    ## All Phase Artifacts

    ```json
    #{artifacts_json}
    ```

    ## Instructions

    1. Check each functional requirement was implemented
    2. Review code changes for correctness
    3. Verify acceptance criteria are met
    4. Run tests if available
    5. Identify any gaps between requirements and implementation

    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "requirements_met": [
        {
          "req_id": "FR-1",
          "met": true,
          "evidence": "How this was verified"
        }
      ],
      "gaps": ["Any unmet requirements or issues found"],
      "overall_verdict": "pass",
      "summary": "Brief summary of validation results"
    }
    ```

    Set `overall_verdict` to "fail" if any must-have requirements are not met.
    """
  end
end
