defmodule Hive.Doctor do
  @moduledoc """
  Health checks and auto-fixes for the Hive environment.

  Each check is a small, focused function that inspects one aspect of the
  system and returns a result map. The Doctor runs all checks in sequence,
  reports their status, and can optionally auto-fix issues that have a
  known remediation path.

  Check results follow a uniform shape:

      %{name: atom(), status: :ok | :warn | :error, message: String.t(), fixable: boolean()}

  This is a pure diagnostic module -- no GenServer, no state. Every function
  transforms system observations into structured health reports.
  """

  alias Hive.Store

  @type check_result :: %{
          name: atom(),
          status: :ok | :warn | :error,
          message: String.t(),
          fixable: boolean()
        }

  @checks [
    :git_installed,
    :claude_installed,
    :hive_initialized,
    :database_ok,
    :config_valid,
    :settings_valid,
    :orphan_cells,
    :stale_bees,
    :queen_workspace,
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
    results = Enum.map(@checks, &check/1)

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
  def check(:claude_installed), do: check_claude_installed()
  def check(:hive_initialized), do: check_hive_initialized()
  def check(:database_ok), do: check_database_ok()
  def check(:config_valid), do: check_config_valid()
  def check(:settings_valid), do: check_settings_valid()
  def check(:orphan_cells), do: check_orphan_cells()
  def check(:stale_bees), do: check_stale_bees()
  def check(:queen_workspace), do: check_queen_workspace()
  def check(:disk_space), do: check_disk_space()

  @doc """
  Attempts to fix a specific check by name.

  Only some checks are fixable. Returns the check result after attempting
  the fix.
  """
  @spec fix(atom()) :: check_result()
  def fix(:orphan_cells), do: fix_orphan_cells()
  def fix(:stale_bees), do: fix_stale_bees()
  def fix(:queen_workspace), do: fix_queen_workspace()
  def fix(:config_valid), do: fix_config_valid()
  def fix(:settings_valid), do: fix_settings_valid()
  def fix(name), do: %{name: name, status: :error, message: "Not fixable", fixable: false}

  @doc """
  Returns the list of all check names.
  """
  @spec checks() :: [atom()]
  def checks, do: @checks

  # -- Individual checks -----------------------------------------------------

  defp check_git_installed do
    case Hive.Git.git_version() do
      {:ok, version} ->
        result(:git_installed, :ok, "git #{version}")

      {:error, _} ->
        result(:git_installed, :error, "git is not installed or not in PATH")
    end
  end

  defp check_claude_installed do
    case Hive.Runtime.Claude.find_executable() do
      {:ok, path} ->
        result(:claude_installed, :ok, "Found at #{path}")

      {:error, :not_found} ->
        result(:claude_installed, :error, "Claude CLI not found. Install from https://claude.ai/cli")
    end
  end

  defp check_hive_initialized do
    case Hive.hive_dir() do
      {:ok, path} ->
        result(:hive_initialized, :ok, "Hive at #{path}")

      {:error, :not_in_hive} ->
        result(:hive_initialized, :error, "Not inside a hive workspace. Run `hive init`.")
    end
  end

  defp check_database_ok do
    Store.count(:bees)
    result(:database_ok, :ok, "Store is accessible")
  rescue
    e ->
      result(:database_ok, :error, "Store error: #{Exception.message(e)}")
  end

  defp check_config_valid do
    case Hive.hive_dir() do
      {:ok, path} ->
        config_path = Path.join([path, ".hive", "config.toml"])

        case Hive.Config.read_config(config_path) do
          {:ok, _config} ->
            result(:config_valid, :ok, "Config is valid")

          {:error, reason} ->
            result(:config_valid, :error, "Config error: #{inspect(reason)}", true)
        end

      {:error, _} ->
        result(:config_valid, :warn, "Cannot check config: not in a hive workspace")
    end
  end

  defp check_settings_valid do
    case Hive.hive_dir() do
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
        result(:settings_valid, :warn, "Cannot check: not in a hive workspace")
    end
  end

  defp check_orphan_cells do
    count = count_orphan_cells()

    case count do
      0 ->
        result(:orphan_cells, :ok, "No orphan cells", false)

      n ->
        result(:orphan_cells, :warn, "#{n} orphan cell(s) found", true)
    end
  end

  defp check_stale_bees do
    count = count_stale_bees()

    case count do
      0 ->
        result(:stale_bees, :ok, "No stale bees", false)

      n ->
        result(:stale_bees, :warn, "#{n} stale bee(s) found", true)
    end
  end

  defp check_queen_workspace do
    case Hive.hive_dir() do
      {:ok, path} ->
        queen_md = Path.join([path, ".hive", "queen", "QUEEN.md"])

        if File.exists?(queen_md) do
          result(:queen_workspace, :ok, "QUEEN.md exists")
        else
          result(:queen_workspace, :error, "QUEEN.md is missing from .hive/queen/", true)
        end

      {:error, _} ->
        result(:queen_workspace, :warn, "Cannot check: not in a hive workspace")
    end
  end

  defp check_disk_space do
    case Hive.hive_dir() do
      {:ok, path} ->
        hive_path = Path.join(path, ".hive")
        size_bytes = dir_size(hive_path)
        size_mb = size_bytes / (1024 * 1024)

        cond do
          size_mb > 1024 ->
            result(:disk_space, :warn, ".hive directory is #{format_size(size_bytes)} (over 1 GB)")

          true ->
            result(:disk_space, :ok, ".hive directory is #{format_size(size_bytes)}")
        end

      {:error, _} ->
        result(:disk_space, :warn, "Cannot check: not in a hive workspace")
    end
  end

  # -- Fix implementations ---------------------------------------------------

  defp fix_orphan_cells do
    case Hive.Cell.cleanup_orphans() do
      {:ok, 0} ->
        result(:orphan_cells, :ok, "No orphan cells to fix", false)

      {:ok, count} ->
        result(:orphan_cells, :ok, "Fixed #{count} orphan cell(s)", false)
    end
  end

  defp fix_stale_bees do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    count =
      Store.update_matching(
        :bees,
        fn b -> b.status in ["starting", "working"] and (b.pid == "" or is_nil(b.pid)) end,
        fn b -> %{b | status: "crashed", updated_at: now} end
      )

    case count do
      0 ->
        result(:stale_bees, :ok, "No stale bees to fix", false)

      n ->
        result(:stale_bees, :ok, "Marked #{n} stale bee(s) as crashed", false)
    end
  end

  defp fix_queen_workspace do
    case Hive.hive_dir() do
      {:ok, path} ->
        queen_dir = Path.join([path, ".hive", "queen"])
        queen_md = Path.join(queen_dir, "QUEEN.md")

        with :ok <- File.mkdir_p(queen_dir),
             :ok <- File.write(queen_md, Hive.Init.queen_instructions()) do
          result(:queen_workspace, :ok, "Regenerated QUEEN.md")
        else
          {:error, reason} ->
            result(:queen_workspace, :error, "Failed to regenerate QUEEN.md: #{inspect(reason)}")
        end

      {:error, _} ->
        result(:queen_workspace, :error, "Cannot fix: not in a hive workspace")
    end
  end

  defp fix_config_valid do
    case Hive.hive_dir() do
      {:ok, path} ->
        config_path = Path.join([path, ".hive", "config.toml"])

        case Hive.Config.write_config(config_path) do
          :ok ->
            result(:config_valid, :ok, "Regenerated config.toml with defaults")

          {:error, reason} ->
            result(:config_valid, :error, "Failed to regenerate config.toml: #{inspect(reason)}")
        end

      {:error, _} ->
        result(:config_valid, :error, "Cannot fix: not in a hive workspace")
    end
  end

  defp fix_settings_valid do
    case Hive.hive_dir() do
      {:ok, path} ->
        regenerated = 0

        # Regenerate queen settings
        queen_workspace = Path.join([path, ".hive", "queen"])

        regenerated =
          if File.dir?(queen_workspace) do
            case Hive.Runtime.Settings.generate_queen(path, queen_workspace) do
              :ok -> regenerated + 1
              _ -> regenerated
            end
          else
            regenerated
          end

        # Regenerate active cell settings
        active_cells =
          try do
            Store.filter(:cells, fn c -> c.status == "active" end)
          rescue
            _ -> []
          end

        regenerated =
          Enum.reduce(active_cells, regenerated, fn cell, acc ->
            bee_id = cell.bee_id
            worktree = cell.worktree_path

            if bee_id && worktree && File.dir?(worktree) do
              case Hive.Runtime.Settings.generate(bee_id, path, worktree) do
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
        result(:settings_valid, :error, "Cannot fix: not in a hive workspace")
    end
  end

  defp maybe_fix(%{status: status, fixable: true, name: name}) when status in [:warn, :error] do
    fix(name)
  end

  defp maybe_fix(result), do: result

  # -- Query helpers ---------------------------------------------------------

  defp count_orphan_cells do
    active_cells = Store.filter(:cells, fn c -> c.status == "active" end)

    Enum.count(active_cells, fn cell ->
      case Store.get(:bees, cell.bee_id) do
        nil -> true
        bee -> bee.status in ["stopped", "crashed"]
      end
    end)
  rescue
    _ -> 0
  end

  defp count_stale_bees do
    Store.count(:bees, fn b ->
      b.status in ["starting", "working"] and (b.pid == "" or is_nil(b.pid))
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

  defp collect_settings_files(hive_root) do
    queen_settings = Path.join([hive_root, ".hive", "queen", ".claude", "settings.json"])

    cell_settings =
      try do
        Store.filter(:cells, fn c -> c.status == "active" end)
        |> Enum.map(fn cell ->
          Path.join([cell.worktree_path, ".claude", "settings.json"])
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
