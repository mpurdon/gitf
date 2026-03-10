defmodule Hive.AgentProfile do
  @moduledoc """
  Manages expert agent profiles for bee workers.

  Before a bee starts work, this module checks if the comb has a Claude
  agent file matching the job's technology. If not, it generates one using
  Claude to create an expert profile.

  Agent files are stored per-comb in `<comb_path>/.claude/agents/` and are
  discovered automatically by Claude Code at runtime. Once generated, they
  are cached (the file persists) and reused by all bees on that comb.
  """

  alias Hive.AgentProfile.FailureModes

  require Logger

  @agents_dir ".claude/agents"

  # Comb-level dependency detection: {pattern, agent_key}
  # Used by detect_from_comb/1 to scan project manifest files.
  @pyproject_deps [
    {"strands-agents", "strands-sdk"},
    {"strands-agents-builder", "strands-sdk"},
    {"fastapi", "fastapi"},
    {"django", "django"},
    {"flask", "flask"},
    {"boto3", "aws"},
    {"sagemaker", "aws"},
    {"pulumi", "python"}
  ]

  @package_json_deps [
    {"react-native", "react-native"},
    {"next", "nextjs"},
    {"@angular/core", "angular"},
    {"vue", "vue"},
    {"svelte", "svelte"},
    {"react", "react"},
    {"express", "javascript"},
    {"fastify", "javascript"}
  ]

  @mix_deps [
    {":phoenix_live_view", "phoenix-liveview"},
    {":phoenix", "phoenix"},
    {":ecto", "elixir"},
    {":nerves", "elixir"},
    {":nx", "elixir"}
  ]

  # Tiered detection rules: {priority, keywords, agent_key}
  # Priority 1 = multi-keyword combos (most specific)
  # Priority 2 = specific frameworks/SDKs
  # Priority 3 = base languages (broadest fallback)
  #
  # Detection uses AND logic (all keywords must match), then picks the
  # lowest priority number. Ties broken by keyword count (more = more specific).
  @detection_rules [
    # Priority 1: Multi-keyword combos
    {1, ["strands", "agent"], "strands-sdk"},
    {1, ["strands", "sdk"], "strands-sdk"},
    {1, ["cdk", "infrastructure"], "aws-cdk"},
    {1, ["cdk", "stack"], "aws-cdk"},
    {1, ["terraform", "module"], "terraform-iac"},
    {1, ["terraform", "infrastructure"], "terraform-iac"},
    {1, ["phoenix", "liveview"], "phoenix-liveview"},
    {1, ["phoenix", "live"], "phoenix-liveview"},
    {1, ["react", "native"], "react-native"},
    {1, ["next", "react"], "nextjs"},
    {1, ["otp", "genserver"], "elixir-otp"},
    {1, ["otp", "supervisor"], "elixir-otp"},
    {1, ["otp", "supervision"], "elixir-otp"},

    # Priority 2: Specific frameworks/SDKs
    {2, ["nextjs"], "nextjs"},
    {2, ["next.js"], "nextjs"},
    {2, ["fastapi"], "fastapi"},
    {2, ["phoenix"], "phoenix"},
    {2, ["django"], "django"},
    {2, ["flask"], "flask"},
    {2, ["rails"], "rails"},
    {2, ["cdk"], "aws-cdk"},
    {2, ["strands"], "strands-sdk"},
    {2, ["genserver"], "elixir-otp"},
    {2, ["tailwind"], "tailwind"},
    {2, ["graphql"], "graphql"},
    {2, ["kubernetes"], "kubernetes"},
    {2, ["k8s"], "kubernetes"},
    {2, ["docker"], "docker"},
    {2, ["terraform"], "terraform"},
    {2, ["lambda"], "aws-lambda"},
    {2, ["vue"], "vue"},
    {2, ["angular"], "angular"},
    {2, ["svelte"], "svelte"},
    {2, ["react"], "react"},

    # Priority 3: Base languages
    {3, ["elixir"], "elixir"},
    {3, ["otp"], "elixir"},
    {3, ["python"], "python"},
    {3, ["typescript"], "typescript"},
    {3, ["javascript"], "javascript"},
    {3, ["node"], "javascript"},
    {3, ["rust"], "rust"},
    {3, ["cargo"], "rust"},
    {3, ["go"], "go"},
    {3, ["golang"], "go"},
    {3, ["ruby"], "ruby"},
    {3, ["java"], "java"},
    {3, ["kotlin"], "kotlin"},
    {3, ["swift"], "swift"},
    {3, ["css"], "css"},
    {3, ["sql"], "sql"},
    {3, ["postgres"], "sql"},
    {3, ["postgresql"], "sql"},
    {3, ["mysql"], "sql"},
    {3, ["sqlite"], "sql"},
    {3, ["aws"], "aws"},
    {3, ["c++"], "cpp"},
    {3, ["cpp"], "cpp"}
  ]

  # Maps agent keys to human-readable technology labels
  @base_technology_map %{
    "strands-sdk" => "Python/Strands SDK",
    "aws-cdk" => "AWS CDK",
    "aws-lambda" => "AWS Lambda",
    "terraform-iac" => "Terraform IaC",
    "phoenix-liveview" => "Phoenix LiveView",
    "phoenix" => "Phoenix/Elixir",
    "elixir-otp" => "Elixir/OTP",
    "elixir" => "Elixir",
    "nextjs" => "Next.js",
    "react-native" => "React Native",
    "react" => "React",
    "fastapi" => "FastAPI",
    "django" => "Django",
    "flask" => "Flask",
    "rails" => "Ruby on Rails",
    "vue" => "Vue.js",
    "angular" => "Angular",
    "svelte" => "Svelte",
    "tailwind" => "Tailwind CSS",
    "graphql" => "GraphQL",
    "kubernetes" => "Kubernetes",
    "docker" => "Docker",
    "terraform" => "Terraform",
    "typescript" => "TypeScript",
    "javascript" => "JavaScript",
    "python" => "Python",
    "rust" => "Rust",
    "go" => "Go",
    "ruby" => "Ruby",
    "java" => "Java",
    "kotlin" => "Kotlin",
    "swift" => "Swift",
    "css" => "CSS",
    "sql" => "SQL",
    "aws" => "AWS",
    "cpp" => "C++"
  }

  @doc """
  Ensures an expert agent file exists for the given job in the comb.

  1. Detects the technology from the job title/description
  2. If an agent file already exists, returns its path
  3. If not, generates one via Claude and returns the path
  4. If no technology is detected, returns `{:ok, :no_agent}`

  This function is safe to call from a GenServer `handle_continue` --
  the Claude generation runs synchronously but within the async provision
  pipeline.
  """
  @spec ensure_agent(String.t(), map()) :: {:ok, String.t()} | {:ok, :no_agent} | {:error, term()}
  def ensure_agent(comb_path, job) do
    title = Map.get(job, :title, "") || ""
    description = Map.get(job, :description, "") || ""

    # Early exit: if any agent already exists for this comb, reuse it (one agent per comb)
    case existing_agent(comb_path) do
      {:ok, path} ->
        Logger.info("Agent profile already exists: #{Path.basename(path)}")
        {:ok, path}

      :none ->
        # Comb-level detection first, then fall back to job-level
        agent_key = detect_from_comb(comb_path) || detect_technology(title, description)

        case agent_key do
          nil ->
            {:ok, :no_agent}

          key ->
            Logger.info("Generating agent profile: #{key}-expert")
            generate_agent(comb_path, key, title, description)
        end
    end
  end

  @doc """
  Detects the primary technology from job title and description.

  Uses tiered keyword matching against detection rules. Rules are prioritized:
  priority 1 (multi-keyword combos) beats priority 2 (specific frameworks)
  beats priority 3 (base languages). Within the same priority, rules with
  more keywords win (more specific). Returns the agent key as a string or
  nil if no match.
  """
  @spec detect_technology(String.t(), String.t()) :: String.t() | nil
  def detect_technology(title, description) do
    text = String.downcase("#{title} #{description}")

    @detection_rules
    |> Enum.filter(fn {_priority, keywords, _agent_key} ->
      Enum.all?(keywords, &String.contains?(text, &1))
    end)
    |> Enum.sort_by(fn {priority, keywords, _agent_key} ->
      {priority, -length(keywords)}
    end)
    |> case do
      [{_priority, _keywords, agent_key} | _] -> agent_key
      [] -> nil
    end
  end

  @doc """
  Detects the primary technology from the comb's project manifest files.

  Scans `pyproject.toml`, `package.json`, and `mix.exs` at the comb root
  for known dependency packages. Returns the most specific agent_key found
  (frameworks beat languages), or nil if nothing is detected.
  """
  @spec detect_from_comb(String.t()) :: String.t() | nil
  def detect_from_comb(comb_path) do
    detections =
      [
        detect_pyproject(comb_path),
        detect_package_json(comb_path),
        detect_mix_exs(comb_path)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    # Pick the most specific: use the detection_rules priority to rank
    # agent_keys (lower priority number = more specific)
    priority_for = fn agent_key ->
      case Enum.find(@detection_rules, fn {_p, _kw, key} -> key == agent_key end) do
        {priority, _kw, _key} -> priority
        nil -> 99
      end
    end

    detections
    |> Enum.sort_by(priority_for)
    |> List.first()
  end

  @doc """
  Generates an expert agent file for the given technology.

  Uses Claude headless to generate the content, then writes it to the
  comb's `.claude/agents/` directory. The job title and description are
  included in the generation prompt so Claude can produce a specific,
  scenario-aware agent profile.
  """
  @spec generate_agent(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def generate_agent(comb_path, agent_key, title \\ "", description \\ "") do
    agent_name = "#{agent_key}-expert"
    agents_dir = Path.join(comb_path, @agents_dir)
    agent_path = Path.join(agents_dir, "#{agent_name}.md")

    # Ensure .claude/agents/ directory exists
    File.mkdir_p!(agents_dir)

    prompt = build_generation_prompt(agent_key, agent_name, title, description)

    anti_patterns = FailureModes.format_for_agent(:all)

    case generate_via_model(comb_path, prompt) do
      {:ok, content} ->
        File.write!(agent_path, content <> "\n\n" <> anti_patterns)
        Logger.info("Agent profile generated: #{agent_path}")
        {:ok, agent_path}

      {:error, reason} ->
        Logger.warning("Failed to generate agent #{agent_name}: #{inspect(reason)}")
        # Write a fallback agent file with job context
        fallback = build_fallback_agent(agent_key, agent_name, title, description)
        File.write!(agent_path, fallback <> "\n\n" <> anti_patterns)
        {:ok, agent_path}
    end
  end

  @doc """
  Copies all agent profiles from a comb's agents directory into a worktree.

  Claude Code discovers agents from `.claude/agents/` relative to the git root.
  Since bee worktrees have their own git root, agents generated at the comb level
  must be copied into each worktree for Claude to discover them.
  """
  @spec install_agents(String.t(), String.t()) :: :ok
  def install_agents(comb_path, worktree_path) do
    src_dir = Path.join(comb_path, @agents_dir)
    dst_dir = Path.join(worktree_path, @agents_dir)

    if File.dir?(src_dir) do
      File.mkdir_p!(dst_dir)

      src_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        src = Path.join(src_dir, filename)
        dst = Path.join(dst_dir, filename)

        unless File.exists?(dst) do
          File.cp!(src, dst)
        end
      end)
    end

    :ok
  end

  @doc """
  Lists all agent profiles available in a comb's agents directory.
  """
  @spec list_agents(String.t()) :: [String.t()]
  def list_agents(comb_path) do
    agents_dir = Path.join(comb_path, @agents_dir)

    if File.dir?(agents_dir) do
      agents_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(&Path.rootname/1)
    else
      []
    end
  end

  # -- Private: helpers --------------------------------------------------------

  defp base_technology(agent_key) do
    Map.get(@base_technology_map, agent_key, humanize(agent_key))
  end

  defp humanize(agent_key) do
    agent_key
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # -- Private: generation -----------------------------------------------------

  defp build_generation_prompt(agent_key, agent_name, title, description) do
    tech_label = base_technology(agent_key)

    job_context =
      case {title, description} do
        {"", ""} -> ""
        {t, ""} -> "\nThe job this agent will work on: \"#{t}\"\n"
        {"", d} -> "\nThe job context: \"#{d}\"\n"
        {t, d} -> "\nThe job this agent will work on: \"#{t}\"\nJob details: \"#{d}\"\n"
      end

    """
    Generate a Claude Code agent file for a #{tech_label} expert. Output ONLY the agent file content with no extra explanation.
    #{job_context}
    The file MUST use this exact YAML frontmatter format:

    ---
    name: #{agent_name}
    description: Use this agent when working on #{tech_label} code. [Expand with 2-4 specific example usage scenarios showing user messages and agent responses, like the example below.]
    model: sonnet
    color: blue
    ---

    Example description format (adapt for #{tech_label}):
    ```
    description: Use this agent when the user needs to write or design #{tech_label} code.\\n\\nExamples:\\n\\n- user: "Example request"\\n  assistant: "I'll use this agent to help."\\n  Commentary: Why this agent is the right choice.
    ```

    After the frontmatter, write a comprehensive #{tech_label} expert agent in markdown with this structure:

    1. **Identity paragraph** (2-3 sentences): Who this expert is, their philosophy, what makes them exceptional at #{tech_label}.

    2. **Core Philosophy** (heading ##): 3-5 numbered subsections (### 1. Title), each a paragraph explaining a fundamental principle. These should be *specific to #{tech_label}* — reference actual patterns, APIs, and idioms by name. Experts have opinions — take strong positions.

    3. **Technical Standards** (heading ##): 4-6 subsections (### Title) with specific bullet points covering code structure, patterns, testing, and error handling. Reference actual #{tech_label} libraries, functions, and conventions by name. Be prescriptive, not generic.

    4. **Working Style** (heading ##): 5-7 numbered items describing how this expert approaches problems, communicates decisions, and challenges assumptions. These should reflect deep #{tech_label} expertise.

    Requirements:
    - Reference actual APIs, libraries, patterns, and tools by name — not generic "follow best practices"
    - Take strong, opinionated positions that a real #{tech_label} expert would hold
    - Target 70-120 lines of markdown after the frontmatter
    - No generic filler like "write clean code" — every bullet should be specific to #{tech_label}
    - Include only the YAML frontmatter and markdown instructions, nothing else
    """
  end

  defp generate_via_model(comb_path, prompt) do
    Hive.AgentProfile.Generation.generate_via_model(prompt, comb_path)
  end

  defp build_fallback_agent(agent_key, agent_name, title, description) do
    tech_label = base_technology(agent_key)

    job_context =
      case {title, description} do
        {"", ""} ->
          ""

        {t, ""} ->
          """

          ## Job Context

          This agent was generated for a specific task: **#{t}**
          Adapt your expertise to this context when providing guidance.
          """

        {"", d} ->
          """

          ## Job Context

          This agent was generated for the following work:
          #{d}
          Adapt your expertise to this context when providing guidance.
          """

        {t, d} ->
          """

          ## Job Context

          This agent was generated for: **#{t}**
          #{d}
          Adapt your expertise to this context when providing guidance.
          """
      end

    """
    ---
    name: #{agent_name}
    description: Use this agent when working on #{tech_label} code.
    model: sonnet
    color: blue
    ---

    # #{tech_label} Expert

    You are an expert #{tech_label} developer. Write clean, idiomatic code following
    established best practices. Favor pragmatic solutions with reduced complexity.

    ## Core Principles

    1. **Deep Knowledge**: Understand #{tech_label} idioms, patterns, and ecosystem conventions thoroughly before writing code.
    2. **Pragmatic Design**: Favor simple, composable solutions over complex abstractions. The right amount of complexity is the minimum needed.
    3. **Explicit Over Implicit**: Make intent clear through naming, structure, and documentation. Avoid clever tricks that obscure meaning.

    ## Working Style

    1. **Think before coding**: Articulate the approach before implementation. What goes in? What comes out?
    2. **Start with the public API**: Define the interface first, then implement. The API tells the story.
    3. **Explain your reasoning**: When making architectural decisions, explain why. Cite the principle that guides the choice.
    4. **Challenge assumptions**: If a request doesn't fit #{tech_label} idioms, say so and suggest alternatives.
    5. **Provide alternatives**: When there are multiple valid approaches, present them with tradeoffs.
    #{job_context}\
    """
  end

  # Returns {:ok, path} if any .md agent file exists in the comb's agents dir, :none otherwise.
  defp existing_agent(comb_path) do
    agents_dir = Path.join(comb_path, @agents_dir)

    if File.dir?(agents_dir) do
      case File.ls!(agents_dir) |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort() do
        [first | _] -> {:ok, Path.join(agents_dir, first)}
        [] -> :none
      end
    else
      :none
    end
  end

  # -- Private: comb-level detection ------------------------------------------

  defp detect_pyproject(comb_path) do
    path = Path.join(comb_path, "pyproject.toml")

    if File.exists?(path) do
      content = File.read!(path)

      @pyproject_deps
      |> Enum.find_value(fn {pkg, agent_key} ->
        if String.contains?(content, pkg), do: agent_key
      end)
    end
  end

  defp detect_package_json(comb_path) do
    path = Path.join(comb_path, "package.json")

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, json} ->
          deps =
            Map.merge(
              Map.get(json, "dependencies", %{}),
              Map.get(json, "devDependencies", %{})
            )

          dep_keys = Map.keys(deps)

          @package_json_deps
          |> Enum.find_value(fn {pkg, agent_key} ->
            if pkg in dep_keys, do: agent_key
          end)

        _ ->
          nil
      end
    end
  end

  defp detect_mix_exs(comb_path) do
    path = Path.join(comb_path, "mix.exs")

    if File.exists?(path) do
      content = File.read!(path)

      @mix_deps
      |> Enum.find_value(fn {pattern, agent_key} ->
        if String.contains?(content, pattern), do: agent_key
      end)
    end
  end
end
