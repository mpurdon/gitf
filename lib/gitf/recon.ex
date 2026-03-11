defmodule GiTF.Recon do
  @moduledoc """
  Recons are read-only ghosts that examine the codebase before implementation.

  When triage flags a op as complex, a recon ghost is spawned first to
  analyze the codebase, identify relevant files, note patterns and risks,
  and produce structured findings. These findings are injected into the
  parent op's description before the implementation ghost starts.

  This is a pure context module -- no process state, just data transformations.
  """

  require Logger

  alias GiTF.{Jobs, Archive, Triage}

  @sections ~w(relevant_files patterns risks complexity approach)a

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns true if triage says this op is complex and needs scouting.
  """
  @spec should_scout?(map()) :: boolean()
  def should_scout?(op) do
    {complexity, _pipeline} = Triage.triage(op)
    complexity == :complex
  end

  @doc """
  Builds the prompt for a recon ghost.

  Instructs the recon to examine the codebase relevant to the op,
  identify key files, note patterns/conventions, flag risks, assess
  complexity, and output structured markdown findings.
  """
  @spec build_scout_prompt(map()) :: String.t()
  def build_scout_prompt(op) do
    title = Map.get(op, :title, "")
    description = Map.get(op, :description, "")
    target_files = Map.get(op, :target_files, []) |> List.wrap()

    target_section =
      if target_files != [] do
        "\nKnown target files: #{Enum.join(target_files, ", ")}"
      else
        ""
      end

    """
    You are a Recon — a read-only analyst. Your op is to examine the codebase \
    and produce a structured report for the implementation ghost that will follow you.

    DO NOT modify any files. Only read and analyze.

    ## Task to analyze

    **Title:** #{title}

    **Description:** #{description}
    #{target_section}

    ## Your mission

    1. Examine the codebase relevant to this task
    2. Identify every file that will likely need modification
    3. Note existing patterns and conventions the implementer must follow
    4. Identify risks, edge cases, and potential issues
    5. Assess the actual complexity of this task
    6. Recommend a concrete implementation approach

    ## Required output format

    Output your findings as markdown with exactly these sections:

    ## Relevant Files
    List each file path on its own line, with a brief note about why it's relevant.

    ## Patterns & Conventions
    Describe the coding patterns, naming conventions, and architectural patterns \
    the implementer must follow.

    ## Risks
    List potential issues, edge cases, breaking changes, or tricky aspects.

    ## Complexity Assessment
    Your honest assessment of the actual complexity (simple/moderate/complex) \
    with justification.

    ## Recommended Approach
    Step-by-step implementation plan the ghost should follow.
    """
  end

  @doc """
  Parses recon output markdown into a structured findings map.

  Extracts sections: relevant_files, patterns, risks, complexity, approach.
  """
  @spec parse_findings(String.t()) :: map()
  def parse_findings(output) when is_binary(output) do
    %{
      relevant_files: extract_file_paths(output),
      patterns: extract_section(output, "Patterns & Conventions"),
      risks: extract_section(output, "Risks"),
      complexity: extract_section(output, "Complexity Assessment"),
      approach: extract_section(output, "Recommended Approach")
    }
  end

  def parse_findings(_), do: empty_findings()

  @doc """
  Injects recon findings into the parent op's description.

  Reads the op from store, prepends a `## Recon Report` section to the
  description, and updates the op in store.
  """
  @spec inject_findings(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def inject_findings(op_id, findings) do
    with {:ok, op} <- Jobs.get(op_id) do
      report = format_report(findings)
      new_description = report <> "\n\n" <> (op.description || "")

      updated = %{op | description: new_description, scout_findings: findings}
      Archive.put(:ops, updated)
    end
  end

  @doc """
  Creates a recon op linked to a parent op.

  The recon op:
  - Has `recon: true` and `scout_for: parent_op_id`
  - Shares the parent's mission_id
  - Uses the provided sector_id
  - Becomes a dependency of the parent (parent depends on recon)
  - Blocks the parent until the recon completes
  """
  @spec create_scout_job(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_scout_job(parent_op_id, sector_id) do
    with {:ok, parent_job} <- Jobs.get(parent_op_id) do
      prompt = build_scout_prompt(parent_job)

      attrs = %{
        title: "[Recon] #{parent_job.title}",
        description: prompt,
        mission_id: parent_job.mission_id,
        sector_id: sector_id,
        recon: true,
        scout_for: parent_op_id,
        skip_verification: true
      }

      with {:ok, scout_job} <- Jobs.create(attrs),
           {:ok, _dep} <- Jobs.add_dependency(parent_op_id, scout_job.id),
           {:ok, _blocked} <- Jobs.block(parent_op_id) do
        Logger.info("Created recon op #{scout_job.id} for parent #{parent_op_id}")
        {:ok, scout_job}
      end
    end
  end

  # -- Private: markdown parsing -----------------------------------------------

  defp extract_section(text, heading) do
    # Match from "## Heading" to the next "## " or end of string
    pattern = ~r/##\s+#{Regex.escape(heading)}\s*\n(.*?)(?=\n##\s|\z)/s

    case Regex.run(pattern, text) do
      [_, content] -> String.trim(content)
      _ -> ""
    end
  end

  defp extract_file_paths(text) do
    section = extract_section(text, "Relevant Files")

    # Match file paths: lines starting with - or * followed by a path-like string
    Regex.scan(~r/[-*]\s+`?([^\s`]+(?:\/[^\s`]+)+)`?/, section)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp format_report(findings) do
    files =
      findings
      |> Map.get(:relevant_files, [])
      |> Enum.map_join("\n", &("- `#{&1}`"))

    """
    ## Recon Report

    ### Relevant Files
    #{files}

    ### Patterns & Conventions
    #{Map.get(findings, :patterns, "")}

    ### Risks
    #{Map.get(findings, :risks, "")}

    ### Complexity Assessment
    #{Map.get(findings, :complexity, "")}

    ### Recommended Approach
    #{Map.get(findings, :approach, "")}
    """
    |> String.trim()
  end

  defp empty_findings do
    Map.new(@sections, &{&1, if(&1 == :relevant_files, do: [], else: "")})
  end
end
