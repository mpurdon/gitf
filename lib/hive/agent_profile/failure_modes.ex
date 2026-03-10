defmodule Hive.AgentProfile.FailureModes do
  @moduledoc """
  Named anti-patterns (failure modes) injected into agent profile `.md` files.

  Bees receive these as explicit "DO NOT" instructions so they avoid common
  mistakes. When a bee fails, the Drone uses `learn_from_failure/2` to
  produce a new, structured anti-pattern from the failure analysis, which
  gets appended to the agent profile for future runs.

  This is a pure context module -- no GenServer, no state. Data in, data out.
  """

  @type severity :: :critical | :high | :medium

  @type mode :: %{
          key: atom(),
          name: String.t(),
          description: String.t(),
          severity: severity()
        }

  @default_modes %{
    rewrite_from_scratch: %{
      key: :rewrite_from_scratch,
      name: "REWRITE_FROM_SCRATCH",
      description: "DO NOT rewrite existing files from scratch. Make targeted, surgical changes.",
      severity: :critical
    },
    modify_outside_scope: %{
      key: :modify_outside_scope,
      name: "MODIFY_OUTSIDE_SCOPE",
      description:
        "DO NOT modify files outside your assigned scope. Only touch files directly related to your task.",
      severity: :critical
    },
    skip_tests: %{
      key: :skip_tests,
      name: "SKIP_TESTS",
      description:
        "DO NOT skip writing or running tests. Every change must be validated.",
      severity: :critical
    },
    ignore_errors: %{
      key: :ignore_errors,
      name: "IGNORE_ERRORS",
      description:
        "DO NOT ignore compiler warnings or test failures. Fix them before marking complete.",
      severity: :critical
    },
    premature_optimization: %{
      key: :premature_optimization,
      name: "PREMATURE_OPTIMIZATION",
      description:
        "DO NOT optimize code that isn't a bottleneck. Focus on correctness first.",
      severity: :medium
    },
    yak_shaving: %{
      key: :yak_shaving,
      name: "YAK_SHAVING",
      description:
        "DO NOT refactor surrounding code or add unrelated improvements. Stay focused on the task.",
      severity: :high
    },
    hallucinate_apis: %{
      key: :hallucinate_apis,
      name: "HALLUCINATE_APIS",
      description:
        "DO NOT invent APIs, functions, or modules that don't exist. Verify imports and calls.",
      severity: :critical
    },
    incomplete_implementation: %{
      key: :incomplete_implementation,
      name: "INCOMPLETE_IMPLEMENTATION",
      description:
        "DO NOT leave TODO comments or partial implementations. Finish what you start.",
      severity: :high
    },
    break_existing: %{
      key: :break_existing,
      name: "BREAK_EXISTING",
      description:
        "DO NOT break existing functionality. Run the full test suite before completing.",
      severity: :critical
    },
    over_engineer: %{
      key: :over_engineer,
      name: "OVER_ENGINEER",
      description:
        "DO NOT add abstractions, configs, or extension points that weren't asked for.",
      severity: :high
    }
  }

  # Job types mapped to additional relevant failure mode keys beyond :critical
  @job_type_modes %{
    "implementation" => [:skip_tests, :incomplete_implementation, :yak_shaving],
    "bugfix" => [:break_existing, :incomplete_implementation],
    "refactor" => [:break_existing, :over_engineer, :yak_shaving],
    "research" => [:premature_optimization, :over_engineer, :hallucinate_apis],
    "testing" => [:skip_tests, :incomplete_implementation],
    "documentation" => [:hallucinate_apis, :incomplete_implementation]
  }

  @doc """
  Returns the default failure modes map.
  """
  @spec defaults() :: %{atom() => mode()}
  def defaults, do: @default_modes

  @doc """
  Formats failure modes as markdown for injection into an agent `.md` file.

  Pass `:all` to include every default mode, or a list of mode keys to
  include only those.

  ## Examples

      iex> Hive.AgentProfile.FailureModes.format_for_agent([:skip_tests])
      "## Anti-Patterns (DO NOT)\\n\\n**SKIP_TESTS** (critical)\\nDO NOT skip writing or running tests. Every change must be validated.\\n"
  """
  @spec format_for_agent(:all | [atom()]) :: String.t()
  def format_for_agent(:all) do
    @default_modes
    |> Map.values()
    |> sort_by_severity()
    |> build_markdown()
  end

  def format_for_agent(keys) when is_list(keys) do
    @default_modes
    |> Map.take(keys)
    |> Map.values()
    |> sort_by_severity()
    |> build_markdown()
  end

  @doc """
  Selects relevant failure mode keys for a job type, augmented by past failures.

  Always includes all `:critical` severity modes. Adds modes specific to the
  `job_type` (e.g. "implementation" gets `:skip_tests`), plus any keys from
  `past_failure_keys` that exist in the defaults.

  ## Examples

      iex> keys = Hive.AgentProfile.FailureModes.select_relevant("implementation", [:premature_optimization])
      iex> :skip_tests in keys
      true
      iex> :premature_optimization in keys
      true
  """
  @spec select_relevant(String.t(), [atom()]) :: [atom()]
  def select_relevant(job_type, past_failure_keys \\ []) do
    critical_keys = critical_mode_keys()
    job_keys = Map.get(@job_type_modes, job_type, [])
    past_keys = Enum.filter(past_failure_keys, &Map.has_key?(@default_modes, &1))

    (critical_keys ++ job_keys ++ past_keys)
    |> Enum.uniq()
  end

  @doc """
  Produces a new failure mode from a failure analysis, or `:skip` if already covered.

  The `failure_analysis` map should contain:
    - `:type` or `:failure_type` -- category of failure
    - `:root_cause` -- what went wrong
    - `:suggestions` -- list of remediation steps

  `existing_modes` is a list of mode maps already in the agent profile.
  If the failure's root cause maps to an existing mode key, returns `:skip`.

  ## Examples

      iex> analysis = %{type: "test_failure", root_cause: "Missing test coverage", suggestions: ["Add unit tests"]}
      iex> {:ok, mode} = Hive.AgentProfile.FailureModes.learn_from_failure(analysis, [])
      iex> mode.severity
      :high
  """
  @spec learn_from_failure(map(), [mode()]) :: {:ok, mode()} | :skip
  def learn_from_failure(failure_analysis, existing_modes) do
    root_cause = extract_root_cause(failure_analysis)
    new_key = slugify(root_cause)

    existing_keys =
      existing_modes
      |> Enum.map(fn mode -> mode[:key] || mode["key"] end)
      |> MapSet.new()

    default_keys = @default_modes |> Map.keys() |> MapSet.new()

    if MapSet.member?(existing_keys, new_key) or MapSet.member?(default_keys, new_key) do
      :skip
    else
      suggestions = extract_suggestions(failure_analysis)
      failure_type = extract_type(failure_analysis)

      description =
        "DO NOT repeat: #{root_cause}. " <>
          if(suggestions != "", do: "Instead: #{suggestions}", else: "Fix before completing.")

      mode = %{
        key: new_key,
        name: new_key |> Atom.to_string() |> String.upcase(),
        description: description,
        severity: infer_severity(failure_type)
      }

      {:ok, mode}
    end
  end

  @doc """
  Formats a learned failure mode as markdown for appending to an agent `.md` file.

  ## Examples

      iex> mode = %{key: :missing_imports, name: "MISSING_IMPORTS", description: "DO NOT forget imports.", severity: :high}
      iex> Hive.AgentProfile.FailureModes.format_learned_mode(mode)
      "### LEARNED: MISSING_IMPORTS (from failure)\\nDO NOT forget imports.\\n"
  """
  @spec format_learned_mode(mode()) :: String.t()
  def format_learned_mode(%{name: name, description: description}) do
    "### LEARNED: #{name} (from failure)\n#{description}\n"
  end

  # -- Private helpers --------------------------------------------------------

  defp sort_by_severity(modes) do
    priority = %{critical: 0, high: 1, medium: 2}
    Enum.sort_by(modes, &Map.get(priority, &1.severity, 3))
  end

  defp build_markdown([]), do: ""

  defp build_markdown(modes) do
    header = "## Anti-Patterns (DO NOT)\n\n"

    body =
      modes
      |> Enum.map_join("\n", fn mode ->
        "**#{mode.name}** (#{mode.severity})\n#{mode.description}"
      end)

    header <> body <> "\n"
  end

  defp critical_mode_keys do
    @default_modes
    |> Enum.filter(fn {_key, mode} -> mode.severity == :critical end)
    |> Enum.map(fn {key, _mode} -> key end)
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 50)
    |> String.to_atom()
  end

  defp extract_root_cause(analysis) do
    Map.get(analysis, :root_cause) ||
      Map.get(analysis, "root_cause") ||
      "Unknown failure"
  end

  defp extract_type(analysis) do
    Map.get(analysis, :type) ||
      Map.get(analysis, :failure_type) ||
      Map.get(analysis, "type") ||
      :unknown
  end

  defp extract_suggestions(analysis) do
    raw = Map.get(analysis, :suggestions) || Map.get(analysis, "suggestions") || []

    case raw do
      list when is_list(list) -> Enum.join(list, "; ")
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp infer_severity(failure_type) do
    type_str = to_string(failure_type) |> String.downcase()

    cond do
      String.contains?(type_str, "crash") -> :critical
      String.contains?(type_str, "compilation") -> :critical
      String.contains?(type_str, "test") -> :high
      String.contains?(type_str, "timeout") -> :high
      true -> :high
    end
  end
end
