defmodule Hive.Runtime.Settings do
  @moduledoc """
  Generates `.claude/settings.json` for bee working directories.

  Each bee needs a settings file that wires Claude Code's hook system into
  the hive. The `SessionStart` hook primes the bee with its job context,
  and the `Stop` hook records cost data back to the hive database.

  In API mode, no settings file is needed (no CLI process to configure),
  so generation is skipped.

  This is a pure data-transformation module: takes a bee ID and hive root,
  produces a JSON file on disk.
  """

  @doc """
  Generates and writes `.claude/settings.json` into the given working directory.

  The settings configure Claude Code hooks:

  - `SessionStart`: runs `hive prime --bee <bee_id>` to inject context
  - `Stop`: runs `hive costs record --bee <bee_id>` to capture cost data

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec generate(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def generate(bee_id, hive_root, working_dir) do
    if Hive.Runtime.ModelResolver.api_mode?() do
      # API mode: no CLI process, no settings file needed
      :ok
    else
      case Hive.Runtime.Models.workspace_setup(bee_id, hive_root) do
        nil ->
          :ok

        settings ->
          write_settings_json(working_dir, settings)
      end
    end
  end

  @doc """
  Builds the settings map without writing to disk.

  Useful for testing or inspection.
  """
  @spec build_settings(String.t(), String.t(), keyword()) :: map()
  def build_settings(bee_id, hive_root, opts \\ []) do
    hive_bin = hive_binary_path(hive_root)
    env_prefix = server_env_prefix()
    risk_level = Keyword.get(opts, :risk_level, :low)

    %{
      "permissions" => %{
        "allow" => allowed_tools(hive_bin, risk_level)
      },
      "hooks" => %{
        "SessionStart" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{env_prefix}#{hive_bin} prime --bee #{bee_id}"}
            ]
          }
        ],
        "Stop" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{env_prefix}#{hive_bin} costs record --bee #{bee_id}"}
            ]
          }
        ]
      }
    }
  end

  @doc """
  Builds settings for the Queen's interactive Claude session.

  Includes the same tool permissions as bee settings, plus hooks for
  queen-specific priming and cost recording.
  """
  @spec build_queen_settings(String.t()) :: map()
  def build_queen_settings(hive_root) do
    hive_bin = hive_binary_path(hive_root)

    %{
      "permissions" => %{
        "allow" => queen_allowed_tools(hive_bin)
      },
      "hooks" => %{
        "SessionStart" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{hive_bin} prime --queen"}
            ]
          }
        ],
        "Stop" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{hive_bin} costs record --queen"}
            ]
          }
        ]
      }
    }
  end

  @doc """
  Generates and writes settings into the queen workspace `.claude/` directory.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec generate_queen(String.t(), String.t()) :: :ok | {:error, term()}
  def generate_queen(hive_root, queen_workspace) do
    if Hive.Runtime.ModelResolver.api_mode?() do
      # API mode: no CLI process, no settings file needed
      :ok
    else
      case Hive.Runtime.Models.workspace_setup("queen", hive_root) do
        nil ->
          :ok

        settings ->
          write_settings_json(queen_workspace, settings)
      end
    end
  end

  @doc """
  Generates settings for a bee's cell worktree.

  Writes both `.claude/settings.json` (local settings) and
  `.claude/settings.json` at the project level within the worktree.
  This is called during cell provisioning to ensure the bee has
  proper permissions before Claude launches.
  """
  @spec generate_for_cell(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def generate_for_cell(bee_id, hive_root, worktree_path) do
    generate(bee_id, hive_root, worktree_path)
  end

  # -- Private ---------------------------------------------------------------

  defp write_settings_json(working_dir, settings) do
    claude_dir = Path.join(working_dir, ".claude")
    settings_path = Path.join(claude_dir, "settings.json")

    with :ok <- File.mkdir_p(claude_dir),
         json = Jason.encode!(settings, pretty: true),
         :ok <- File.write(settings_path, json) do
      :ok
    end
  end

  defp queen_allowed_tools(hive_bin) do
    [
      "Bash(#{hive_bin}:*)",
      "Bash(git:*)",
      "Bash(ls:*)",
      "Read",
      "Glob",
      "Grep"
    ]
  end

  defp allowed_tools(hive_bin, :low) do
    [
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(mix:*)",
      "Bash(cargo:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(make:*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(cat:*)",
      "Bash(#{hive_bin}:*)"
    ]
  end

  defp allowed_tools(hive_bin, :medium) do
    # No rm
    [
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(mix:*)",
      "Bash(cargo:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(make:*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(cat:*)",
      "Bash(#{hive_bin}:*)"
    ]
  end

  defp allowed_tools(hive_bin, :high) do
    # No rm, mv, cp, limited Bash
    [
      "Bash(git:*)",
      "Bash(mix:*)",
      "Bash(npm:*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cat:*)",
      "Bash(#{hive_bin}:*)"
    ]
  end

  defp allowed_tools(hive_bin, :critical) do
    # Read-only + hive CLI only
    [
      "Read",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(#{hive_bin}:*)"
    ]
  end

  # When generating settings from a running server, prefix hook commands
  # with HIVE_SERVER so they use remote mode instead of booting a second app.
  defp server_env_prefix do
    case Hive.Web.Endpoint.config(:http) do
      [_ | _] = http ->
        port = Keyword.get(http, :port, 4000)
        "HIVE_SERVER=http://localhost:#{port} "

      _ ->
        ""
    end
  rescue
    # Endpoint not started (local mode, no server)
    _ -> ""
  end

  defp hive_binary_path(hive_root) do
    local_bin = Path.join(hive_root, "hive")

    if File.exists?(local_bin) do
      local_bin
    else
      "hive"
    end
  end
end
