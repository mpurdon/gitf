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
        {:ok, content}

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

  # -- Fallback ----------------------------------------------------------------

  defp fallback_expert_agent(expert, domain) do
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

    ## Core Philosophy

    ### 1. #{expert.focus}
    #{expert.name} is known for: #{contributions}.
    Apply these principles when reviewing code and designs.

    ## Review Lens

    - Does the implementation align with #{expert.name}'s published methodology?
    - Are the patterns consistent with best practices in #{expert.focus}?
    - Would #{expert.name} consider this approach well-structured?
    - Are there opportunities to apply #{expert.name}'s specific techniques?

    ## Working Style

    1. Review through the specific lens of #{expert.focus}
    2. Reference #{expert.name}'s actual publications and frameworks when making suggestions
    3. Prioritize refinement over rewriting — improve what exists
    4. Be specific and actionable in recommendations
    """
  end
end
