defmodule GiTF.Scout do
  @moduledoc """
  Scouts are read-only ghosts that examine the codebase before implementation.

  When triage flags a job as complex, a scout ghost is spawned first to
  analyze the codebase, identify relevant files, note patterns and risks,
  and produce structured findings. These findings are injected into the
  parent job's description before the implementation ghost starts.

  This is a pure context module -- no process state, just data transformations.
  """

  require Logger

  alias GiTF.{Jobs, Store, Triage}

  @sections ~w(relevant_files patterns risks complexity approach)a

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns true if triage says this job is complex and needs scouting.
  """
  @spec should_scout?(map()) :: boolean()
  def should_scout?(job) do
    {complexity, _pipeline} = Triage.triage(job)
    complexity == :complex
  end

  @doc """
  Builds the prompt for a scout ghost.

  Instructs the scout to examine the codebase relevant to the job,
  identify key files, note patterns/conventions, flag risks, assess
  complexity, and output structured markdown findings.
  """
  @spec build_scout_prompt(map()) :: String.t()
  def build_scout_prompt(job) do
    title = Map.get(job, :title, "")
    description = Map.get(job, :description, "")
    target_files = Map.get(job, :target_files, []) |> List.wrap()

    target_section =
      if target_files != [] do
        "\nKnown target files: #{Enum.join(target_files, ", ")}"
      else
        ""
      end

    """
    You are a Scout — a read-only analyst. Your job is to examine the codebase \
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
  Parses scout output markdown into a structured findings map.

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
  Injects scout findings into the parent job's description.

  Reads the job from store, prepends a `## Scout Report` section to the
  description, and updates the job in store.
  """
  @spec inject_findings(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def inject_findings(job_id, findings) do
    with {:ok, job} <- Jobs.get(job_id) do
      report = format_report(findings)
      new_description = report <> "\n\n" <> (job.description || "")

      updated = %{job | description: new_description, scout_findings: findings}
      Store.put(:jobs, updated)
    end
  end

  @doc """
  Creates a scout job linked to a parent job.

  The scout job:
  - Has `scout: true` and `scout_for: parent_job_id`
  - Shares the parent's quest_id
  - Uses the provided comb_id
  - Becomes a dependency of the parent (parent depends on scout)
  - Blocks the parent until the scout completes
  """
  @spec create_scout_job(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_scout_job(parent_job_id, comb_id) do
    with {:ok, parent_job} <- Jobs.get(parent_job_id) do
      prompt = build_scout_prompt(parent_job)

      attrs = %{
        title: "[Scout] #{parent_job.title}",
        description: prompt,
        quest_id: parent_job.quest_id,
        comb_id: comb_id,
        scout: true,
        scout_for: parent_job_id,
        skip_verification: true
      }

      with {:ok, scout_job} <- Jobs.create(attrs),
           {:ok, _dep} <- Jobs.add_dependency(parent_job_id, scout_job.id),
           {:ok, _blocked} <- Jobs.block(parent_job_id) do
        Logger.info("Created scout job #{scout_job.id} for parent #{parent_job_id}")
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
    ## Scout Report

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
