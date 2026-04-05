defmodule GiTF.Medic do
  @moduledoc """
  Health checks and auto-fixes for the GiTF environment.

  Each check is a small, focused function that inspects one aspect of the
  system and returns a result map. The Medic runs all checks in sequence,
  reports their status, and can optionally auto-fix issues that have a
  known remediation path.

  Check results follow a uniform shape:

      %{name: atom(), status: :ok | :warn | :error, message: String.t(), fixable: boolean()}

  This is a pure diagnostic module -- no GenServer, no state. Every function
  transforms system observations into structured health reports.
  """

  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

  @type check_result :: %{
          name: atom(),
          status: :ok | :warn | :error,
          message: String.t(),
          fixable: boolean()
        }

  @checks [
    :git_installed,
    :model_configured,
    :gitf_initialized,
    :database_ok,
    :config_valid,
    :settings_valid,
    :orphan_shells,
    :stale_ghosts,
    :major_workspace,
    :disk_space
  ]

  # -- Public API ------------------------------------------------------------

  @doc """
  Runs all health checks and returns a list of results.

  ## Options

    * `:fix` - when `true`, automatically fixes any fixable issues after
      the initial check run. Defaults to `false`.

  Returns a list of check result maps.
  """
  @spec run_all(keyword()) :: [check_result()]
  def run_all(opts \\ []) do
    checks_to_run =
      if "ollama" in GiTF.Runtime.ProviderManager.provider_priority() do
        @checks ++ [:ollama_running]
      else
        @checks
      end

    results = Enum.map(checks_to_run, &check/1)

    if Keyword.get(opts, :fix, false) do
      Enum.map(results, &maybe_fix/1)
    else
      results
    end
  end

  @doc """
  Runs a single check by name.

  Returns a check result map.
  """
  @spec check(atom()) :: check_result()
  def check(:git_installed), do: check_git_installed()
  def check(:model_configured), do: check_model_configured()
  def check(:gitf_initialized), do: check_section_initialized()
  def check(:database_ok), do: check_database_ok()
  def check(:config_valid), do: check_config_valid()
  def check(:settings_valid), do: check_settings_valid()
  def check(:orphan_shells), do: check_orphan_cells()
  def check(:stale_ghosts), do: check_stale_ghosts()
  def check(:major_workspace), do: check_major_workspace()
  def check(:disk_space), do: check_disk_space()
  def check(:ollama_running), do: check_ollama_running()

  @doc """
  Attempts to fix a specific check by name.

  Only some checks are fixable. Returns the check result after attempting
  the fix.
  """
  @spec fix(atom()) :: check_result()
  def fix(:orphan_shells), do: fix_orphan_cells()
  def fix(:stale_ghosts), do: fix_stale_ghosts()
  def fix(:major_workspace), do: fix_major_workspace()
  def fix(:config_valid), do: fix_config_valid()
  def fix(:settings_valid), do: fix_settings_valid()
  def fix(:ollama_running), do: fix_ollama_running()
  def fix(name), do: %{name: name, status: :error, message: "Not fixable", fixable: false}

  @doc """
  Returns the list of all check names.
  """
  @spec checks() :: [atom()]
  def checks, do: @checks

  # -- Individual checks -----------------------------------------------------

  defp check_ollama_running do
    if GiTF.Runtime.Ollama.running?() do
      case GiTF.Runtime.Ollama.list_models() do
        {:ok, models} ->
          result(:ollama_running, :ok, "Ollama running (#{length(models)} models)")

        _ ->
          result(:ollama_running, :ok, "Ollama running")
      end
    else
      result(:ollama_running, :error, "Ollama is not running (start with `ollama serve`)", true)
    end
  end

  defp check_git_installed do
    case GiTF.Git.git_version() do
      {:ok, version} ->
        result(:git_installed, :ok, "git #{version}")

      {:error, _} ->
        result(:git_installed, :error, "git is not installed or not in PATH")
    end
  end

  defp check_model_configured do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # API mode: check that a relevant API key is set
      provider = default_provider()

      case provider do
        "google" ->
          if has_key?("GOOGLE_API_KEY") || has_key?("GEMINI_API_KEY") ||
               config_key("google_api_key") do
            result(:model_configured, :ok, "API mode with Google (key set)")
          else
            result(
              :model_configured,
              :error,
              "GOOGLE_API_KEY not set. Set env var or [llm] keys.google_api_key in .gitf/config.toml."
            )
          end

        "anthropic" ->
          if has_key?("ANTHROPIC_API_KEY") || config_key("anthropic_api_key") do
            result(:model_configured, :ok, "API mode with Anthropic (key set)")
          else
            result(
              :model_configured,
              :error,
              "ANTHROPIC_API_KEY not set. Set env var or [llm] keys.anthropic_api_key in .gitf/config.toml."
            )
          end

        "openai" ->
          if has_key?("OPENAI_API_KEY") do
            result(:model_configured, :ok, "API mode with OpenAI (key set)")
          else
            result(:model_configured, :error, "OPENAI_API_KEY not set.")
          end

        _ ->
          result(:model_configured, :ok, "API mode with provider: #{provider}")
      end
    else
      # CLI mode: check that the configured CLI executable exists
      case GiTF.Runtime.Models.find_executable() do
        {:ok, path} ->
          result(:model_configured, :ok, "CLI mode, found at #{path}")

        {:error, :not_found} ->
          result(
            :model_configured,
            :error,
            "CLI executable not found. Switch to API mode or install the CLI."
          )
      end
    end
  end

  defp default_provider do
    model = GiTF.Runtime.ModelResolver.resolve("sonnet")
    GiTF.Runtime.ModelResolver.provider(model)
  rescue
    _ -> "google"
  end

  defp has_key?(env_var), do: System.get_env(env_var) not in [nil, ""]

  defp config_key(key_name) do
    with {:ok, root} <- GiTF.gitf_dir(),
         {:ok, config} <- GiTF.Config.read_config(Path.join([root, ".gitf", "config.toml"])),
         value when is_binary(value) and value != "" <- get_in(config, ["llm", "keys", key_name]) do
      true
    else
      _ -> false
    end
  end

  defp check_section_initialized do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        result(:gitf_initialized, :ok, "GiTF at #{path}")

      {:error, :not_in_gitf} ->
        result(:gitf_initialized, :error, "Not inside a gitf workspace. Run `gitf init`.")
    end
  end

  defp check_database_ok do
    Archive.count(:ghosts)
    result(:database_ok, :ok, "Archive is accessible")
  rescue
    e ->
      result(:database_ok, :error, "Archive error: #{Exception.message(e)}")
  end

  defp check_config_valid do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        config_path = Path.join([path, ".gitf", "config.toml"])

        case GiTF.Config.read_config(config_path) do
          {:ok, _config} ->
            result(:config_valid, :ok, "Config is valid")

          {:error, reason} ->
            result(:config_valid, :error, "Config error: #{inspect(reason)}", true)
        end

      {:error, _} ->
        result(:config_valid, :warn, "Cannot check config: not in a gitf workspace")
    end
  end

  defp check_settings_valid do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        settings_files = collect_settings_files(path)

        case settings_files do
          [] ->
            result(:settings_valid, :ok, "No settings files to check")

          files ->
            old_format_count =
              Enum.count(files, fn file ->
                case File.read(file) do
                  {:ok, content} ->
                    case Jason.decode(content) do
                      {:ok, %{"hooks" => hooks}} -> has_old_format_hooks?(hooks)
                      _ -> false
                    end

                  _ ->
                    false
                end
              end)

            if old_format_count == 0 do
              result(:settings_valid, :ok, "All settings files use current hooks format")
            else
              result(
                :settings_valid,
                :warn,
                "#{old_format_count} settings file(s) use outdated hooks format",
                true
              )
            end
        end

      {:error, _} ->
        result(:settings_valid, :warn, "Cannot check: not in a gitf workspace")
    end
  end

  defp check_orphan_cells do
    count = count_orphan_cells()

    case count do
      0 ->
        result(:orphan_shells, :ok, "No orphan shells", false)

      n ->
        result(:orphan_shells, :warn, "#{n} orphan shell(s) found", true)
    end
  end

  defp check_stale_ghosts do
    count = count_stale_ghosts()

    case count do
      0 ->
        result(:stale_ghosts, :ok, "No stale ghosts", false)

      n ->
        result(:stale_ghosts, :warn, "#{n} stale ghost(s) found", true)
    end
  end

  defp check_major_workspace do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        major_md = Path.join([path, ".gitf", "major", "MAJOR.md"])

        if File.exists?(major_md) do
          result(:major_workspace, :ok, "MAJOR.md exists")
        else
          result(:major_workspace, :error, "MAJOR.md is missing from .gitf/queen/", true)
        end

      {:error, _} ->
        result(:major_workspace, :warn, "Cannot check: not in a gitf workspace")
    end
  end

  defp check_disk_space do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        section_path = Path.join(path, ".gitf")

        # Use df -m to get MB values and a robust regex to extract available space
        {output, 0} = System.cmd("df", ["-m", section_path], stderr_to_stdout: true)

        available_mb =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case Regex.run(~r/(\d+)\s+\d+%\s+/, line) do
              [_, available] ->
                {n, _} = Integer.parse(available)
                n

              _ ->
                nil
            end
          end)

        size_bytes = dir_size(section_path)
        size_mb = size_bytes / (1024 * 1024)

        cond do
          available_mb && available_mb < 200 ->
            result(:disk_space, :error, "Critical: low disk space (#{available_mb} MB available)")

          size_mb > 1024 ->
            result(
              :disk_space,
              :warn,
              ".gitf directory is #{format_size(size_bytes)} (over 1 GB)"
            )

          true ->
            result(
              :disk_space,
              :ok,
              ".gitf directory is #{format_size(size_bytes)} (#{available_mb} MB available)"
            )
        end

      {:error, _} ->
        result(:disk_space, :warn, "Cannot check: not in a gitf workspace")
    end
  end

  # -- Fix implementations ---------------------------------------------------

  defp fix_ollama_running do
    case GiTF.Runtime.Ollama.start_server() do
      {:ok, _} ->
        result(:ollama_running, :ok, "Started Ollama server in the background")

      {:error, :not_installed} ->
        result(
          :ollama_running,
          :error,
          "Ollama is not installed. Please install it from ollama.com",
          false
        )

      {:error, reason} ->
        result(:ollama_running, :error, "Failed to start Ollama: #{inspect(reason)}", false)
    end
  end

  defp fix_orphan_cells do
    case GiTF.Shell.cleanup_orphans() do
      {:ok, 0} ->
        result(:orphan_shells, :ok, "No orphan shells to fix", false)

      {:ok, count} ->
        result(:orphan_shells, :ok, "Fixed #{count} orphan shell(s)", false)
    end
  end

  defp fix_stale_ghosts do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    count =
      Archive.update_matching(
        :ghosts,
        fn b -> GhostStatus.active?(b.status) and (b.pid == "" or is_nil(b.pid)) end,
        fn b -> %{b | status: GhostStatus.crashed(), updated_at: now} end
      )

    case count do
      0 ->
        result(:stale_ghosts, :ok, "No stale ghosts to fix", false)

      n ->
        result(:stale_ghosts, :ok, "Marked #{n} stale ghost(s) as crashed", false)
    end
  end

  defp fix_major_workspace do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        queen_dir = Path.join([path, ".gitf", "major"])
        major_md = Path.join(queen_dir, "MAJOR.md")

        with :ok <- File.mkdir_p(queen_dir),
             :ok <- File.write(major_md, GiTF.Init.major_instructions()) do
          result(:major_workspace, :ok, "Regenerated MAJOR.md")
        else
          {:error, reason} ->
            result(:major_workspace, :error, "Failed to regenerate MAJOR.md: #{inspect(reason)}")
        end

      {:error, _} ->
        result(:major_workspace, :error, "Cannot fix: not in a gitf workspace")
    end
  end

  defp fix_config_valid do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        config_path = Path.join([path, ".gitf", "config.toml"])

        case GiTF.Config.write_config(config_path) do
          :ok ->
            result(:config_valid, :ok, "Regenerated config.toml with defaults")

          {:error, reason} ->
            result(:config_valid, :error, "Failed to regenerate config.toml: #{inspect(reason)}")
        end

      {:error, _} ->
        result(:config_valid, :error, "Cannot fix: not in a gitf workspace")
    end
  end

  defp fix_settings_valid do
    case GiTF.gitf_dir() do
      {:ok, path} ->
        regenerated = 0

        # Regenerate queen settings
        queen_workspace = Path.join([path, ".gitf", "major"])

        regenerated =
          if File.dir?(queen_workspace) do
            case GiTF.Runtime.Settings.generate_major(path, queen_workspace) do
              :ok -> regenerated + 1
              _ -> regenerated
            end
          else
            regenerated
          end

        # Regenerate active shell settings
        active_cells =
          try do
            Archive.filter(:shells, fn c -> c.status == "active" end)
          rescue
            _ -> []
          end

        regenerated =
          Enum.reduce(active_cells, regenerated, fn shell, acc ->
            ghost_id = shell.ghost_id
            worktree = shell.worktree_path

            if ghost_id && worktree && File.dir?(worktree) do
              case GiTF.Runtime.Settings.generate(ghost_id, path, worktree) do
                :ok -> acc + 1
                _ -> acc
              end
            else
              acc
            end
          end)

        if regenerated > 0 do
          result(:settings_valid, :ok, "Regenerated #{regenerated} settings file(s)")
        else
          result(:settings_valid, :ok, "No settings files needed regeneration")
        end

      {:error, _} ->
        result(:settings_valid, :error, "Cannot fix: not in a gitf workspace")
    end
  end

  defp maybe_fix(%{status: status, fixable: true, name: name}) when status in [:warn, :error] do
    fix(name)
  end

  defp maybe_fix(result), do: result

  # -- Query helpers ---------------------------------------------------------

  defp count_orphan_cells do
    active_cells = Archive.filter(:shells, fn c -> c.status == "active" end)

    Enum.count(active_cells, fn shell ->
      case Archive.get(:ghosts, shell.ghost_id) do
        nil -> true
        ghost -> GhostStatus.terminal?(ghost.status)
      end
    end)
  rescue
    _ -> 0
  end

  defp count_stale_ghosts do
    Archive.count(:ghosts, fn b ->
      GhostStatus.active?(b.status) and (b.pid == "" or is_nil(b.pid))
    end)
  rescue
    _ -> 0
  end

  # -- Utility helpers -------------------------------------------------------

  defp result(name, status, message, fixable \\ false) do
    %{name: name, status: status, message: message, fixable: fixable}
  end

  defp dir_size(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.reduce(0, fn entry, acc ->
          acc + dir_size(Path.join(path, entry))
        end)

      {:ok, %{size: size}} ->
        size

      {:error, _} ->
        0
    end
  rescue
    _ -> 0
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp collect_settings_files(gitf_root) do
    queen_settings = Path.join([gitf_root, ".gitf", "major", ".claude", "settings.json"])

    cell_settings =
      try do
        Archive.filter(:shells, fn c -> c.status == "active" end)
        |> Enum.map(fn shell ->
          Path.join([shell.worktree_path, ".claude", "settings.json"])
        end)
      rescue
        _ -> []
      end

    [queen_settings | cell_settings]
    |> Enum.filter(&File.exists?/1)
  end

  defp has_old_format_hooks?(hooks) when is_map(hooks) do
    Enum.any?(hooks, fn {_event, entries} ->
      is_list(entries) and
        Enum.any?(entries, fn
          %{"type" => _} -> true
          _ -> false
        end)
    end)
  end

  defp has_old_format_hooks?(_), do: false
end
