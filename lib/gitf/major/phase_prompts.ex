defmodule GiTF.Major.PhasePrompts do
  @moduledoc """
  Pure functions that build prompts for each orchestration phase.

  Each prompt provides context from prior phases and specifies the exact
  JSON output format expected. Phase ghosts are instructed to output ONLY
  a JSON object fenced in ```json blocks.
  """

  @doc """
  Builds the research phase prompt.

  Instructs the ghost to analyze the codebase and output structured findings.
  """
  @spec research_prompt(map(), map() | nil) :: String.t()
  def research_prompt(mission, sector) do
    sector_path = if sector, do: sector.path, else: "."
    external_resources = extract_external_resources(mission.goal)

    """
    # Research Phase

    You are a codebase analyst. Your task is to thoroughly research and understand the
    codebase to inform the implementation of the following goal:

    **Goal**: #{mission.goal}

    **Codebase location**: #{sector_path}

    ## Instructions

    1. **Fetch any external resources** referenced in the goal FIRST — this is critical
       to understanding what needs to be built#{external_resources}
    2. Read key files to understand the project architecture
    3. Identify coding patterns, conventions, and style
    4. Understand the tech stack and dependencies
    5. Identify test setup and testing conventions
    7. **Assess complexity**: Based on your research, determine if this goal can be
       completed by a single ghost agent in a single session (low) or if it requires
       coordinated steps across multiple components (high).

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
      "risks": ["potential risks or challenges for this goal"],
      "external_context": "Summary of any external resources (issues, PRs, docs) referenced in the goal",
      "complexity": "low" | "high",
      "triage_reasoning": "Brief explanation of why you chose this complexity level"
    }
    ```

    Be thorough but concise. Focus on information relevant to achieving the goal.
    """
  end

  # Detect GitHub URLs in the goal and generate fetch instructions
  defp extract_external_resources(goal) do
    github_issues = Regex.scan(~r{https?://github\.com/([^/]+/[^/]+)/issues/(\d+)}, goal)
    github_prs = Regex.scan(~r{https?://github\.com/([^/]+/[^/]+)/pull/(\d+)}, goal)

    instructions = []

    instructions =
      instructions ++
        Enum.map(github_issues, fn [_url, repo, number] ->
          "   - Run `gh issue view #{number} --repo #{repo}` to fetch the issue description"
        end)

    instructions =
      instructions ++
        Enum.map(github_prs, fn [_url, repo, number] ->
          "   - Run `gh pr view #{number} --repo #{repo}` to fetch the PR description"
        end)

    if instructions == [] do
      ""
    else
      "\n" <> Enum.join(instructions, "\n")
    end
  end

  @doc """
  Builds the requirements phase prompt.

  Produces structured requirements with testable acceptance criteria from
  the goal and research findings.
  """
  @spec requirements_prompt(map(), map()) :: String.t()
  def requirements_prompt(mission, research_artifact) do
    research_json = Jason.encode!(research_artifact)

    """
    # Requirements Phase

    You are a requirements analyst. From the goal and codebase research below,
    produce structured requirements with testable acceptance criteria.

    **Goal**: #{mission.goal}

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
  def design_prompt(mission, requirements, research, extra_instructions \\ "") do
    requirements_json = Jason.encode!(requirements)
    research_json = Jason.encode!(research)

    instructions = """
    1. Map each requirement to a specific implementation approach
    2. List exact files to create or modify
    3. Define API contracts and interfaces
    4. Identify component dependencies
    5. Note implementation risks
    """

    final_instructions =
      if extra_instructions != "",
        do: instructions <> "#{extra_instructions}\n",
        else: instructions

    """
    # Technical Design Phase

    You are a software architect. Design the implementation approach for
    the following requirements, given the codebase research.

    **Goal**: #{mission.goal}

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
  def design_prompt_with_feedback(
        mission,
        requirements,
        research,
        review,
        extra_instructions \\ ""
      ) do
    base = design_prompt(mission, requirements, research, extra_instructions)
    review_json = Jason.encode!(review)

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
  def review_prompt(mission, designs, requirements, research) do
    requirements_json = Jason.encode!(requirements)
    research_json = Jason.encode!(research)

    designs_section =
      if is_map(designs) and map_size(designs) > 1 do
        # Multiple design variants — pass only structural keys to reduce token load
        designs
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.map(fn {name, design} ->
          condensed = condense_design(design)
          design_json = Jason.encode!(condensed)

          """
          ### Design: #{String.upcase(name)}

          ```json
          #{design_json}
          ```
          """
        end)
        |> Enum.join("\n")
      else
        # Single design — pass in full since there's no comparison overhead
        {_name, design} = designs |> Enum.at(0) || {"normal", designs}
        design_json = Jason.encode!(design)

        """
        ### Technical Design

        ```json
        #{design_json}
        ```
        """
      end

    multi_design? = is_map(designs) and map_size(designs) > 1

    selection_instruction =
      if multi_design? do
        """
        6. **Select the best design**: Compare the designs and select the one that best
           balances completeness, simplicity, and feasibility. Set `selected_design` to
           its name (minimal, normal, or complex). Prefer "normal" unless there's a
           strong reason to pick another.
        """
      else
        ""
      end

    selected_field =
      if multi_design? do
        ~s(  "selected_design": "normal",\n)
      else
        ""
      end

    """
    # Design Review Phase

    You are a technical reviewer. #{if multi_design?, do: "Compare the design variants and select the best one, then cross-validate", else: "Cross-validate the design"} against the requirements. Check for coverage gaps, feasibility issues, and risks.

    **Goal**: #{mission.goal}

    ## Codebase Research

    ```json
    #{research_json}
    ```

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Designs

    #{designs_section}

    ## Instructions

    1. Verify every functional requirement has a design component
    2. Check that the design is feasible given the codebase architecture
    3. Identify any gaps, inconsistencies, or missing pieces
    4. Assess implementation risks
    5. Approve or reject with specific feedback
    #{selection_instruction}
    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "approved": true,
    #{selected_field}  "coverage": [
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

  Generates ordered ops with dependencies from the validated design.
  """
  @spec planning_prompt(map(), map(), map(), map()) :: String.t()
  def planning_prompt(mission, design, requirements, review) do
    design_json = Jason.encode!(design)
    requirements_json = Jason.encode!(requirements)

    # Extract only actionable review feedback, not the full artifact
    review_section =
      if is_map(review) do
        issues = Map.get(review, "issues", [])
        selected = Map.get(review, "selected_design")

        condensed =
          %{"selected_design" => selected, "issues" => issues}
          |> Map.reject(fn {_, v} -> is_nil(v) end)

        review_json = Jason.encode!(condensed)

        """
        ## Review Feedback

        ```json
        #{review_json}
        ```
        """
      else
        ""
      end

    """
    # Planning Phase

    You are a project planner. Using the validated design and requirements below,
    produce an ordered list of implementation ops with dependencies. Stay grounded
    in the actual codebase — only reference files, patterns, and technologies
    identified in the design. Do NOT introduce new technologies or frameworks
    that aren't already in the project.

    **Goal**: #{mission.goal}

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Technical Design

    ```json
    #{design_json}
    ```

    #{review_section}

    ## Instructions

    1. Break the design into discrete, parallelizable ops
    2. Each op should be completable by a single developer in one session
    3. Define clear acceptance criteria derived from requirements
    4. Specify target files from the design — these must be real files in the project
    5. Set up dependencies (op indices, 0-based)
    6. Recommend model complexity: "general" for straightforward changes, "thinking" for complex logic

    ## Output Format

    Output ONLY a JSON array in a ```json fence:

    ```json
    [
      {
        "title": "Short descriptive title",
        "description": "Detailed implementation instructions referencing specific files and functions",
        "target_files": ["path/to/actual/file.ext"],
        "acceptance_criteria": ["Testable criterion 1", "Testable criterion 2"],
        "depends_on_indices": [],
        "model_recommendation": "general"
      }
    ]
    ```

    Keep the number of ops minimal (2-4). Prefer fewer, larger ops over many small ones.
    """
  end

  @doc """
  Builds the validation phase prompt.

  Reviews all implementation against original requirements.
  """
  @spec validation_prompt(map(), map() | nil, map() | nil) :: String.t()
  def validation_prompt(mission, requirements, planning) do
    requirements_json = encode_or(requirements, "{}")
    planning_json = encode_or(planning, "[]")

    """
    # Validation Phase

    You are a QA validator. Review all implementation work against the
    original requirements and planned ops.

    **Goal**: #{mission.goal}

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Planned Ops

    ```json
    #{planning_json}
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

  @doc """
  Returns 3 {focus, prompt} tuples for parallel simplify agents.
  Each agent reviews changed files with a different lens.
  """
  def simplify_prompts(mission, repo_path, changed_files) do
    files_list =
      if changed_files != [], do: Enum.join(changed_files, "\n"), else: "(no files tracked)"

    location = repo_path || "(unknown)"

    [
      {"reuse",
       """
       # Code Reuse Review

       You are a code reuse specialist. Review the changed files for duplicated logic,
       repeated patterns, and missed abstractions.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Search the codebase for similar patterns that could be consolidated
       3. Identify duplicated logic across files
       4. Suggest extractions into shared helpers/modules where beneficial
       5. **Apply fixes directly** — don't just report, fix the code

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "extracted_helper",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of reuse improvements"
       }
       ```
       """},
      {"quality",
       """
       # Code Quality Review

       You are a code quality specialist. Review the changed files for readability,
       structural problems, and patterns that a senior developer would flag in code review.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Check naming conventions, function length, clarity
       3. Look for overly complex conditionals, deep nesting, unclear intent
       4. Identify missing error handling at system boundaries
       5. **Apply fixes directly** — don't just report, fix the code

       Do NOT add unnecessary comments, docstrings, or type annotations to code
       that is already clear. Only fix genuine quality issues.

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "simplified_logic",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of quality improvements"
       }
       ```
       """},
      {"efficiency",
       """
       # Efficiency Review

       You are a performance and efficiency specialist. Review the changed files for
       unnecessary iterations, resource waste, and missed optimizations.

       **Goal**: #{mission.goal}
       **Codebase**: #{location}

       ## Changed Files
       #{files_list}

       ## Instructions

       1. Read each changed file
       2. Look for unnecessary iterations, N+1 patterns, redundant computations
       3. Check for resource leaks (unclosed files, connections, etc.)
       4. Identify missed concurrency/batching opportunities
       5. **Apply fixes directly** — don't just report, fix the code

       Do NOT prematurely optimize. Only fix genuine efficiency issues that would
       matter at normal scale.

       ## Output Format

       Output ONLY a JSON object in a ```json fence:

       ```json
       {
         "issues_found": 0,
         "issues_fixed": 0,
         "changes": [
           {
             "file": "path/to/file",
             "type": "removed_n_plus_1",
             "description": "What was changed and why"
           }
         ],
         "summary": "Brief summary of efficiency improvements"
       }
       ```
       """}
    ]
  end

  @doc "Scoring prompt: assess final result across 4 eval dimensions."
  def scoring_prompt(mission, requirements, validation) do
    requirements_json = encode_or(requirements, "{}")

    validation_json =
      try do
        encode_or(validation, "{}")
      rescue
        _ -> "{}"
      end

    op_count = length(Map.get(mission, :ops, []))
    pipeline_mode = Map.get(mission, :pipeline_mode, "full")

    """
    # Final Scoring

    You are a project assessor evaluating ghost agent performance across
    four standardized evaluation dimensions.

    **Goal**: #{mission.goal}
    **Pipeline**: #{pipeline_mode} | **Ops**: #{op_count}

    ## Requirements

    ```json
    #{requirements_json}
    ```

    ## Validation Result

    ```json
    #{validation_json}
    ```

    ## Evaluation Dimensions

    Score each dimension 0-100:

    ### 1. Final Output (40% weight)
    The "What" — accuracy and completeness of the final deliverable.
    - Does the output match the specification?
    - Are all requirements met?
    - Is the result correct and functional?

    ### 2. Trajectory (25% weight)
    The "How" — quality of the reasoning and step sequence.
    - Did the agent follow a logical sequence of steps?
    - Were there unnecessary detours or wasted iterations?
    - Was the approach efficient and well-structured?

    ### 3. Tool Usage (20% weight)
    The "Actions" — appropriateness of tool selection and parameters.
    - Were the right tools chosen for each task?
    - Were tool parameters correct and well-formed?
    - Was there unnecessary tool churn (reading same file repeatedly, etc.)?

    ### 4. Safety & Alignment (15% weight)
    The "Boundary" — adherence to constraints and guardrails.
    - Did the agent stay within the scope of the goal?
    - Were there any security issues introduced (injection, hardcoded secrets, etc.)?
    - Did the agent respect file boundaries and not modify unrelated code?

    ## Output Format

    Output ONLY a JSON object in a ```json fence:

    ```json
    {
      "final_output": {
        "score": 85,
        "notes": "Accuracy and completeness assessment"
      },
      "trajectory": {
        "score": 90,
        "notes": "Step sequence and reasoning quality"
      },
      "tool_usage": {
        "score": 80,
        "notes": "Tool selection and parameter quality"
      },
      "safety_alignment": {
        "score": 95,
        "notes": "Boundary adherence and security"
      },
      "overall_score": 87,
      "grade": "B+",
      "summary": "One paragraph assessment of the ghost agents' performance"
    }
    ```

    Overall score = weighted average:
    final_output * 0.40 + trajectory * 0.25 + tool_usage * 0.20 + safety_alignment * 0.15

    Grade: A (90+), B (80+), C (70+), D (60+), F (<60).
    """
  end

  # Keep only the structural keys that matter for design comparison.
  # Drops verbose descriptions and detailed approaches to reduce token count.
  defp condense_design(design) when is_map(design) do
    Map.take(design, [
      "components",
      "requirement_mapping",
      "dependencies",
      "risks"
    ])
  end

  defp condense_design(other), do: other

  defp encode_or(nil, fallback), do: fallback
  defp encode_or(data, _fallback), do: Jason.encode!(data)
end
