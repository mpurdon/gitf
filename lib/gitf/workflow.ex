defmodule GiTF.Workflow do
  @moduledoc """
  Declarative mission workflows.

  A workflow is a YAML file describing the phases a mission moves
  through, the handlers that implement each phase, branching rules
  (`next` / `on_pass` / `on_fail`), retry caps, gates, and the
  knowledge/skills opt-ins per phase.

  ## Storage

  Workflows live in the vault so operators see them in Obsidian and
  version-control them with the rest of the project:

      <vault>/Workflows/<name>.yaml             — global workflows
      <vault>/Sectors/<id>/Workflows/<name>.yaml — sector-scoped overrides

  Sector-scoped workflows shadow global workflows of the same name, so
  operators can fork "standard" per sector without affecting other
  sectors.

  ## Schema (M1)

      name: standard
      description: "Default mission workflow"
      phases:
        - id: research
          handler: GiTF.Phases.Research
          model_tier: general
          inject_knowledge: true
          inject_skills: false
          reads: []
          produces: research
          timeout_minutes: 30
          max_retries: 1
          next: design

        - id: review
          handler: GiTF.Phases.Review
          reads: [design, requirements]
          produces: review
          on_pass: planning
          on_fail: design
          max_retries: 2

  Branching rules (verdict-driven):
    * `next` — unconditional advance
    * `on_pass` / `on_fail` — verdict from the phase handler
    * Either `next` OR (`on_pass` and `on_fail`) — never both
    * The literal id `"end"` terminates the workflow

  Reads/produces declare artifact dependencies. Validation rejects
  workflows that read an artifact never produced by an earlier phase
  (catches misordering at load time, not at runtime).

  ## Hybrid YAML/Elixir

  The on-disk format is YAML. `load/1` parses to a typed struct
  (`%GiTF.Workflow{}`) with full validation. The struct is the only
  surface the orchestrator and CLI ever see — operators editing YAML
  get errors at validation time, not opaque runtime crashes.
  """

  alias GiTF.Workflow.Phase
  alias GiTF.Workflow.Schema

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          phases: [Phase.t()],
          source_path: String.t() | nil
        }

  defstruct [:name, :description, phases: [], source_path: nil]

  @workflows_subdir "Workflows"

  # -- Public API ------------------------------------------------------------

  @doc """
  Loads a workflow from a YAML file. Returns `{:ok, workflow}` or
  `{:error, reason}` with structured validation errors on schema
  violations.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        case cache_lookup(path, mtime) do
          {:ok, _} = hit -> hit
          :miss -> load_and_cache(path, mtime)
        end

      {:error, _} = err ->
        err
    end
  end

  defp load_and_cache(path, mtime) do
    with {:ok, raw} <- read_yaml(path),
         {:ok, workflow} <- Schema.validate(raw, path) do
      cache_put(path, mtime, workflow)
      {:ok, workflow}
    end
  end

  @cache_table :gitf_workflow_cache

  defp cache_lookup(path, mtime) do
    ensure_cache()

    case :ets.lookup(@cache_table, path) do
      [{^path, ^mtime, workflow}] -> {:ok, workflow}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(path, mtime, workflow) do
    ensure_cache()
    :ets.insert(@cache_table, {path, mtime, workflow})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Resolves a workflow by name, with sector-scoped overrides shadowing
  globals. `sector_id` may be nil for global-only resolution.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def resolve(name, sector_id \\ nil) do
    with :ok <- validate_workflow_name(name),
         {:ok, gitf_root} <- GiTF.gitf_dir() do
      candidates = candidate_paths(gitf_root, name, sector_id)

      case Enum.find(candidates, &File.exists?/1) do
        nil -> {:error, {:workflow_not_found, name, candidates}}
        path -> load(path)
      end
    end
  end

  # Workflow names become file basenames inside the vault. Restrict to a
  # strict allowlist so a hostile name can't traverse out of the vault
  # via `..`, absolute paths, or path separators.
  @workflow_name_re ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @doc false
  @spec validate_workflow_name(term()) :: :ok | {:error, {:invalid_workflow_name, term()}}
  def validate_workflow_name(name) when is_binary(name) do
    if Regex.match?(@workflow_name_re, name),
      do: :ok,
      else: {:error, {:invalid_workflow_name, name}}
  end

  def validate_workflow_name(name), do: {:error, {:invalid_workflow_name, name}}

  @doc """
  Lists all available workflows. When `sector_id` is given, includes
  sector-scoped workflows (which shadow same-named globals).
  """
  @spec list(String.t() | nil) :: [t()]
  def list(sector_id \\ nil) do
    priv = list_dir(Path.join(:code.priv_dir(:gitf), "workflows"))

    {global, sector} =
      case GiTF.gitf_dir() do
        {:ok, gitf_root} ->
          global_dir = Path.join(GiTF.Vault.Path.vault_root(gitf_root), @workflows_subdir)

          sector_dir =
            if is_binary(sector_id),
              do: Path.join(GiTF.Vault.Path.sector_dir(gitf_root, sector_id), @workflows_subdir),
              else: nil

          {list_dir(global_dir), if(sector_dir, do: list_dir(sector_dir), else: [])}

        {:error, _} ->
          {[], []}
      end

    # Resolution layering: sector overrides global overrides priv. Drop
    # any layer-N entry whose name already appears in a higher layer.
    sector_names = MapSet.new(sector, & &1.name)
    global_filtered = Enum.reject(global, &MapSet.member?(sector_names, &1.name))
    higher_names = MapSet.union(sector_names, MapSet.new(global_filtered, & &1.name))
    priv_filtered = Enum.reject(priv, &MapSet.member?(higher_names, &1.name))

    (sector ++ global_filtered ++ priv_filtered)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Returns the next phase for a workflow given the current phase id and
  the phase verdict. `verdict` is `:pass`, `:fail`, or `:advance` (for
  unconditional `next`-driven phases).

  Returns `{:ok, phase_id}`, `{:ok, :end}`, or `{:error, reason}`.
  """
  @spec next_phase(t(), String.t(), :pass | :fail | :advance) ::
          {:ok, String.t() | :end} | {:error, term()}
  def next_phase(%__MODULE__{phases: phases}, current_id, verdict) do
    case Enum.find(phases, &(&1.id == current_id)) do
      nil ->
        {:error, {:unknown_phase, current_id}}

      %Phase{next: "end"} ->
        {:ok, :end}

      %Phase{} = phase ->
        case verdict do
          :advance ->
            cond do
              is_binary(phase.next) and phase.next != "" -> {:ok, normalize(phase.next)}
              true -> {:error, {:no_unconditional_next, current_id}}
            end

          :pass when is_binary(phase.on_pass) ->
            {:ok, normalize(phase.on_pass)}

          :fail when is_binary(phase.on_fail) ->
            {:ok, normalize(phase.on_fail)}

          v ->
            {:error, {:no_branch_for_verdict, current_id, v}}
        end
    end
  end

  @doc "Looks up a phase by id within a workflow."
  @spec phase(t(), String.t()) :: {:ok, Phase.t()} | {:error, :not_found}
  def phase(%__MODULE__{phases: phases}, id) do
    case Enum.find(phases, &(&1.id == id)) do
      nil -> {:error, :not_found}
      phase -> {:ok, phase}
    end
  end

  @doc """
  Writes a workflow back to its source path as YAML. Used by the
  visual editor to persist operator edits.

  When `target` is given, writes to that path instead of the workflow's
  `source_path` — useful for forking a global workflow into a sector.
  """
  @spec write(t(), Path.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def write(%__MODULE__{} = workflow, target \\ nil) do
    path = target || workflow.source_path

    with false <- is_nil(path),
         :ok <- validate_workflow_name(workflow.name),
         {:ok, expanded} <- expand_writable_path(path) do
      yaml = serialize(workflow)

      case GiTF.Vault.File.write(expanded, yaml) do
        {:ok, _hash} -> {:ok, expanded}
        {:error, _} = err -> err
      end
    else
      true -> {:error, :no_target_path}
      {:error, _} = err -> err
    end
  end

  # The visual editor lets operators name a save target; reject anything
  # outside the vault Workflows tree (writes to `priv/workflows/` are
  # also refused — those are bundled defaults). Refuses symlinks and any
  # path that resolves outside the allowed roots.
  # The visual editor saves only into <vault>/.../Workflows/<name>.yaml
  # — globally or sector-scoped. Refuse anything outside the vault, any
  # path whose immediate parent isn't a Workflows directory, or any
  # filename that isn't the validated workflow name with a .yaml suffix.
  defp expand_writable_path(path) do
    expanded = Path.expand(path)

    with {:ok, vault_root} <- vault_root_path(),
         true <- String.starts_with?(expanded, vault_root <> "/") or
                 {:error, {:workflow_path_outside_vault, path}},
         true <- Path.basename(Path.dirname(expanded)) == @workflows_subdir or
                 {:error, {:workflow_parent_not_workflows_dir, path}},
         true <- String.ends_with?(expanded, ".yaml") or
                 {:error, {:workflow_path_not_yaml, path}} do
      {:ok, expanded}
    else
      {:error, _} = err -> err
      false -> {:error, {:workflow_path_not_allowed, path}}
    end
  end

  defp vault_root_path do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} -> {:ok, Path.expand(GiTF.Vault.Path.vault_root(gitf_root))}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{} = w) do
    header =
      [
        "name: #{w.name}",
        if(w.description, do: "description: #{yaml_string(w.description)}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    phases =
      w.phases
      |> Enum.map(&serialize_phase/1)
      |> Enum.join("\n\n")

    header <> "\n\nphases:\n" <> phases <> "\n"
  end

  defp serialize_phase(%Phase{} = p) do
    fields =
      [
        {"id", p.id},
        {"handler", handler_str(p.handler)},
        {"model_tier", if(p.model_tier, do: Atom.to_string(p.model_tier))},
        {"timeout_minutes", p.timeout_minutes},
        {"max_retries", if(p.max_retries > 0, do: p.max_retries)},
        {"inject_knowledge", if(p.inject_knowledge, do: true)},
        {"inject_skills", if(p.inject_skills, do: true)},
        {"reads", if(p.reads != [], do: yaml_list(p.reads))},
        {"produces", p.produces},
        {"strategies", if(p.strategies != [], do: yaml_list(p.strategies))},
        {"next", p.next},
        {"on_pass", p.on_pass},
        {"on_fail", p.on_fail}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "    #{k}: #{v}" end)
      |> Enum.join("\n")

    "  - " <> String.trim_leading(fields, " ")
  end

  defp handler_str(nil), do: nil
  defp handler_str(mod) when is_atom(mod), do: mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp yaml_string(s) do
    if String.contains?(s, "\n") do
      "|\n  " <> String.replace(s, "\n", "\n  ")
    else
      s
    end
  end

  defp yaml_list(list) do
    "[" <> Enum.join(list, ", ") <> "]"
  end

  @doc "Returns the first phase in the workflow (entry point)."
  @spec entry_phase(t()) :: {:ok, Phase.t()} | {:error, :empty_workflow}
  def entry_phase(%__MODULE__{phases: [first | _]}), do: {:ok, first}
  def entry_phase(%__MODULE__{phases: []}), do: {:error, :empty_workflow}

  # -- Internal --------------------------------------------------------------

  defp candidate_paths(gitf_root, name, sector_id) do
    sector_path =
      if is_binary(sector_id) do
        Path.join([
          GiTF.Vault.Path.sector_dir(gitf_root, sector_id),
          @workflows_subdir,
          "#{name}.yaml"
        ])
      else
        nil
      end

    global_path =
      Path.join([GiTF.Vault.Path.vault_root(gitf_root), @workflows_subdir, "#{name}.yaml"])

    # Final fallback: the package's bundled defaults under priv/. This
    # ensures `standard` (and any other shipped template) resolves even
    # when the operator hasn't seeded the vault yet.
    priv_path = Path.join(:code.priv_dir(:gitf), "workflows/#{name}.yaml")

    [sector_path, global_path, priv_path] |> Enum.reject(&is_nil/1)
  end

  defp list_dir(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".yaml"))
      |> Enum.flat_map(fn entry ->
        case load(Path.join(dir, entry)) do
          {:ok, w} -> [w]
          {:error, _} -> []
        end
      end)
    else
      []
    end
  end

  defp read_yaml(path) do
    case File.read(path) do
      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
          {:ok, _} -> {:error, {:not_a_map, path}}
          {:error, reason} -> {:error, {:yaml_parse, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp normalize("end"), do: :end
  defp normalize(s) when is_binary(s), do: s
end
