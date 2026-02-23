defmodule Hive.Council.Generator do
  @moduledoc """
  Expert discovery and agent file generation for councils.

  Two-step process using the active model provider:

  1. **Discovery**: Model researches the domain (via web search if available),
     returns structured JSON with expert details.
  2. **Per-expert generation**: For each expert, model researches their specific
     work and generates a full agent .md file embodying their published positions.
  """

  require Logger

  alias Hive.AgentProfile.Generation

  @doc """
  Discovers experts for a domain using the active model provider.

  Returns `{:ok, [expert]}` where each expert is a map with keys:
  `:name`, `:key`, `:focus`, `:contributions`, `:philosophy`, `:reference`.

  Returns `{:error, reason}` if discovery fails.
  """
  @spec discover_experts(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def discover_experts(domain, opts \\ []) do
    count = Keyword.get(opts, :experts, 5)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    prompt = discovery_prompt(domain, count)

    case Generation.generate_via_model(prompt, cwd) do
      {:ok, raw_output} ->
        parse_experts(raw_output)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an expert agent markdown file for a single expert.

  Uses the model to research the expert's methodology and generate a
  Claude Code agent file embodying their positions.

  Returns `{:ok, content}` with the markdown content, or `{:error, reason}`.
  """
  @spec generate_expert_agent(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_expert_agent(expert, domain, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    prompt = expert_agent_prompt(expert, domain)

    case Generation.generate_via_model(prompt, cwd) do
      {:ok, content} ->
        if validate_agent_content(content) do
          {:ok, content}
        else
          Logger.warning("Generated agent for #{expert.name} failed validation, using fallback")
          {:ok, fallback_expert_agent(expert, domain)}
        end

      {:error, reason} ->
        Logger.warning("Failed to generate agent for #{expert.name}: #{inspect(reason)}")
        {:ok, fallback_expert_agent(expert, domain)}
    end
  end

  # -- Prompts -----------------------------------------------------------------

  defp discovery_prompt(domain, count) do
    """
    Research the domain "#{domain}" and identify #{count} real-world recognized experts \
    who have shaped modern best practices in this field.

    For each expert, research and provide:
    1. Full name
    2. A unique kebab-case key (e.g., "ethan-marcotte")
    3. Their primary area of focus within the domain
    4. 2-3 specific, verifiable contributions (books, frameworks, talks, methodologies)
    5. Their core philosophy in 1-2 sentences
    6. One key publication URL or reference

    Search the web for current authorities. Every person MUST be real and verifiable.
    Return ONLY a JSON array with keys: name, key, focus, contributions, philosophy, reference.
    No markdown formatting, no explanation — just the raw JSON array.
    """
  end

  defp expert_agent_prompt(expert, domain) do
    contributions = expert.contributions |> Enum.join(", ")
    reference = Map.get(expert, :reference, "")

    """
    Research #{expert.name} and their work on #{expert.focus} within #{domain}.

    Known contributions: #{contributions}
    Reference: #{reference}

    Search for their published methodology, key talks, and frameworks. Then generate \
    a Claude Code agent file that embodies #{expert.name}'s actual positions. \
    Reference their specific books, talks, and frameworks by name.

    The file MUST use this exact YAML frontmatter format:

    ---
    name: #{expert.key}-expert
    description: Use this agent for #{domain} reviews through the lens of #{expert.name}'s methodology on #{expert.focus}.
    model: sonnet
    color: blue
    ---

    After the frontmatter, write the agent instructions in markdown:

    1. **Identity paragraph** (2-3 sentences): You are channeling #{expert.name}, known for #{expert.focus}. \
    State their philosophy and what makes their perspective unique.

    2. **Core Philosophy** (heading ##): 3-5 numbered subsections (### 1. Title), each a paragraph \
    explaining a fundamental principle from #{expert.name}'s work. Reference their actual publications by name.

    3. **Review Lens** (heading ##): 4-6 specific bullet points describing what this expert looks for \
    when reviewing code/designs. These should be concrete, actionable checks derived from their methodology.

    4. **Working Style** (heading ##): 3-5 numbered items describing how this expert approaches \
    code review — their priorities, communication style, and what they challenge.

    Requirements:
    - Reference actual publications, frameworks, and methodologies by name
    - Take strong, opinionated positions that #{expert.name} would actually hold
    - Target 60-100 lines of markdown after the frontmatter
    - Every bullet should be specific to #{expert.name}'s actual published work
    - Include only the YAML frontmatter and markdown instructions, nothing else
    """
  end

  # -- Parsing -----------------------------------------------------------------

  defp parse_experts(raw_output) do
    # Try to extract a JSON array from the output
    case extract_json_array(raw_output) do
      {:ok, list} when is_list(list) ->
        experts =
          Enum.map(list, fn item ->
            %{
              name: item["name"] || "",
              key: item["key"] || slugify(item["name"] || ""),
              focus: item["focus"] || "",
              contributions: List.wrap(item["contributions"]),
              philosophy: item["philosophy"] || "",
              reference: item["reference"] || ""
            }
          end)
          |> Enum.reject(fn e -> e.name == "" end)

        {:ok, experts}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp extract_json_array(text) do
    # Try direct decode first
    case Jason.decode(String.trim(text)) do
      {:ok, list} when is_list(list) ->
        {:ok, list}

      _ ->
        # Try to find a JSON array in the text (model may wrap in markdown)
        case Regex.run(~r/\[[\s\S]*\]/, text) do
          [json_str | _] ->
            case Jason.decode(json_str) do
              {:ok, list} when is_list(list) -> {:ok, list}
              _ -> {:error, :invalid_json}
            end

          nil ->
            {:error, :no_json_array_found}
        end
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  # -- Validation --------------------------------------------------------------

  @doc """
  Validates that generated agent content is well-formed markdown with
  correct frontmatter and required sections.

  Returns `true` if the content passes all checks, `false` otherwise.
  """
  @spec validate_agent_content(String.t()) :: boolean()
  def validate_agent_content(content) when is_binary(content) do
    lines = String.split(content, "\n")

    has_frontmatter?(content) and
      has_required_sections?(content) and
      length(lines) > 20
  end

  def validate_agent_content(_), do: false

  defp has_frontmatter?(content) do
    # Must start with --- and have a closing ---
    trimmed = String.trim(content)
    String.starts_with?(trimmed, "---") and
      Regex.match?(~r/\A---\n[\s\S]*?\n---/m, trimmed)
  end

  defp has_required_sections?(content) do
    lower = String.downcase(content)
    Enum.all?(["core philosophy", "review lens", "working style"], fn section ->
      String.contains?(lower, section)
    end)
  end

  # -- Fallback ----------------------------------------------------------------

  @doc """
  Generates a fallback expert agent markdown template when the model is unavailable.

  Includes domain-specific review checklists for common software engineering
  concerns (performance, security, maintainability, testing).
  """
  def fallback_expert_agent(expert, domain) do
    contributions = expert.contributions |> Enum.join(", ")

    """
    ---
    name: #{expert.key}-expert
    description: Use this agent for #{domain} reviews through the lens of #{expert.name}'s methodology on #{expert.focus}.
    model: sonnet
    color: blue
    ---

    # #{expert.name} — #{expert.focus}

    You are channeling #{expert.name}, a recognized authority on #{expert.focus} within #{domain}.
    #{expert.philosophy}
    Your reviews are grounded in real-world experience and published methodology.

    ## Core Philosophy

    ### 1. #{expert.focus}
    #{expert.name} is known for: #{contributions}.
    Apply these principles when reviewing code and designs.

    ### 2. Maintainability
    Code should be easy to understand, modify, and extend. Favor clarity over cleverness.
    Every abstraction should earn its place by reducing overall complexity, not adding to it.

    ### 3. Correctness
    Correct behavior is non-negotiable. Edge cases, error handling, and invariants must be
    explicitly considered. Silent failures are worse than loud crashes.

    ## Review Lens

    - Does the implementation align with #{expert.name}'s published methodology on #{expert.focus}?
    - Are the patterns consistent with established best practices in #{domain}?
    - **Performance**: Are there unnecessary allocations, N+1 queries, or missing caching opportunities?
    - **Security**: Are inputs validated at system boundaries? Are secrets properly handled?
    - **Maintainability**: Is the code self-documenting? Are abstractions at the right level?
    - **Testing**: Are critical paths covered? Are edge cases and error paths tested?
    - **Error handling**: Do failures surface clearly rather than being silently swallowed?
    - Are there opportunities to apply #{expert.name}'s specific techniques?

    ## Working Style

    1. Review through the specific lens of #{expert.focus} as practiced by #{expert.name}
    2. Reference #{expert.name}'s actual publications and frameworks when making suggestions
    3. Prioritize refinement over rewriting — improve what exists rather than starting over
    4. Be specific and actionable in recommendations — cite the exact line or pattern to change
    5. Flag security and correctness issues as blocking; style issues as suggestions
    """
  end
end
