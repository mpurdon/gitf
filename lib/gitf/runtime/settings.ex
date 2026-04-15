defmodule GiTF.Runtime.Settings do
  @moduledoc """
  Generates `.claude/settings.json` for ghost working directories.

  Each ghost needs a settings file that wires Claude Code's hook system into
  the section. The `SessionStart` hook primes the ghost with its op context,
  and the `Stop` hook records cost data back to the section database.

  In API mode, no settings file is needed (no CLI process to configure),
  so generation is skipped.

  This is a pure data-transformation module: takes a ghost ID and gitf root,
  produces a JSON file on disk.
  """

  @doc """
  Generates and writes `.claude/settings.json` into the given working directory.

  The settings configure Claude Code hooks:

  - `SessionStart`: runs `gitf brief --ghost <ghost_id>` to inject context
  - `Stop`: runs `gitf costs record --ghost <ghost_id>` to capture cost data

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec generate(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def generate(ghost_id, gitf_root, working_dir) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # API mode: no CLI process, no settings file needed
      :ok
    else
      case GiTF.Runtime.Models.workspace_setup(ghost_id, gitf_root) do
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
  def build_settings(ghost_id, gitf_root, opts \\ []) do
    gitf_bin = gitf_binary_path(gitf_root)
    env_prefix = server_env_prefix()
    risk_level = Keyword.get(opts, :risk_level, :low)

    %{
      "permissions" => %{
        "allow" => allowed_tools(gitf_bin, risk_level)
      },
      "hooks" => %{
        "SessionStart" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{
                "type" => "command",
                "command" => "#{env_prefix}#{gitf_bin} brief --ghost #{ghost_id}"
              }
            ]
          }
        ],
        "Stop" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{
                "type" => "command",
                "command" => "#{env_prefix}#{gitf_bin} costs record --ghost #{ghost_id}"
              }
            ]
          }
        ]
      }
    }
  end

  @doc """
  Builds settings for the Major's interactive Claude session.

  Includes the same tool permissions as ghost settings, plus hooks for
  major-specific priming and cost recording.
  """
  @spec build_major_settings(String.t()) :: map()
  def build_major_settings(gitf_root) do
    gitf_bin = gitf_binary_path(gitf_root)

    %{
      "permissions" => %{
        "allow" => major_allowed_tools(gitf_bin)
      },
      "hooks" => %{
        "SessionStart" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{gitf_bin} brief --major"}
            ]
          }
        ],
        "Stop" => [
          %{
            "matcher" => "",
            "hooks" => [
              %{"type" => "command", "command" => "#{gitf_bin} costs record --major"}
            ]
          }
        ]
      }
    }
  end

  @doc """
  Generates and writes settings into the major workspace `.claude/` directory.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec generate_major(String.t(), String.t()) :: :ok | {:error, term()}
  def generate_major(gitf_root, major_workspace) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # API mode: no CLI process, no settings file needed
      :ok
    else
      case GiTF.Runtime.Models.workspace_setup("major", gitf_root) do
        nil ->
          :ok

        settings ->
          write_settings_json(major_workspace, settings)
      end
    end
  end

  @doc """
  Generates settings for a ghost's shell worktree.

  Writes both `.claude/settings.json` (local settings) and
  `.claude/settings.json` at the project level within the worktree.
  This is called during shell provisioning to ensure the ghost has
  proper permissions before Claude launches.
  """
  @spec generate_for_shell(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def generate_for_shell(ghost_id, gitf_root, worktree_path) do
    generate(ghost_id, gitf_root, worktree_path)
  end

  # -- Role-based settings.local.json -----------------------------------------

  @doc """
  Generates a `.claude/settings.local.json` file that restricts tool access
  based on the ghost's role.

  Recons get read-only access, builders get full access with safety rails,
  and reviewers get read plus test-runner access.

  This is written as `settings.local.json` (not `settings.json`) so it
  layers on top of the base settings without overwriting hooks.

  Returns `:ok`.
  """
  @spec generate_role_settings(:recon | :builder | :reviewer, String.t()) :: :ok
  def generate_role_settings(role, worktree_path) do
    role
    |> role_permissions()
    |> write_settings_local_json(worktree_path)
  end

  @doc """
  Returns the permissions map for a given role without writing to disk.

  Useful for testing or inspection.
  """
  @spec role_permissions(:recon | :builder | :reviewer) :: map()
  def role_permissions(:recon) do
    %{
      "permissions" => %{
        "allow" => [
          "Read",
          "Glob",
          "Grep",
          "Bash(git status:*)",
          "Bash(git log:*)",
          "Bash(git diff:*)",
          "Bash(git show:*)",
          "Bash(ls:*)",
          "Bash(find:*)",
          "Bash(wc:*)",
          "Bash(file:*)"
        ],
        "deny" => [
          "Write",
          "Edit",
          "NotebookEdit",
          "Bash(rm:*)",
          "Bash(mv:*)",
          "Bash(cp:*)",
          "Bash(mkdir:*)",
          "Bash(touch:*)",
          "Bash(chmod:*)",
          "Bash(git push:*)",
          "Bash(git checkout:*)",
          "Bash(git reset:*)"
        ]
      }
    }
  end

  def role_permissions(:builder) do
    %{
      "permissions" => %{
        "allow" => [
          "Read",
          "Write",
          "Edit",
          "Glob",
          "Grep",
          "Bash(*)"
        ],
        "deny" => [
          "Bash(git push:*)",
          "Bash(git checkout main:*)",
          "Bash(git checkout master:*)",
          "Bash(rm -rf /:*)"
        ]
      }
    }
  end

  def role_permissions(:reviewer) do
    %{
      "permissions" => %{
        "allow" => [
          "Read",
          "Glob",
          "Grep",
          "Bash(git:*)",
          "Bash(mix test:*)",
          "Bash(npm test:*)",
          "Bash(bun test:*)",
          "Bash(cargo test:*)",
          "Bash(pytest:*)",
          "Bash(go test:*)"
        ],
        "deny" => [
          "Write",
          "Edit",
          "NotebookEdit",
          "Bash(rm:*)",
          "Bash(git push:*)"
        ]
      }
    }
  end

  # -- Private ---------------------------------------------------------------

  defp write_settings_local_json(settings, worktree_path) do
    claude_dir = Path.join(worktree_path, ".claude")
    settings_path = Path.join(claude_dir, "settings.local.json")

    with :ok <- File.mkdir_p(claude_dir),
         json = Jason.encode!(settings, pretty: true),
         :ok <- File.write(settings_path, json) do
      :ok
    end
  end

  defp write_settings_json(working_dir, settings) do
    claude_dir = Path.join(working_dir, ".claude")
    settings_path = Path.join(claude_dir, "settings.json")

    with :ok <- File.mkdir_p(claude_dir),
         json = Jason.encode!(settings, pretty: true),
         :ok <- File.write(settings_path, json) do
      :ok
    end
  end

  defp major_allowed_tools(gitf_bin) do
    [
      "Bash(#{gitf_bin}:*)",
      "Bash(git:*)",
      "Bash(ls:*)",
      "Read",
      "Glob",
      "Grep"
    ]
  end

  defp allowed_tools(gitf_bin, :low) do
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
      "Bash(#{gitf_bin}:*)"
    ]
  end

  defp allowed_tools(gitf_bin, :medium) do
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
      "Bash(#{gitf_bin}:*)"
    ]
  end

  defp allowed_tools(gitf_bin, :high) do
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
      "Bash(#{gitf_bin}:*)"
    ]
  end

  defp allowed_tools(gitf_bin, :critical) do
    # Read-only + section CLI only
    [
      "Read",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(#{gitf_bin}:*)"
    ]
  end

  # When generating settings from a running server, prefix hook commands
  # with GITF_SERVER so they use remote mode instead of booting a second app.
  defp server_env_prefix do
    case GiTF.Web.Endpoint.config(:http) do
      [_ | _] = http ->
        port = Keyword.get(http, :port, 4000)
        "GITF_SERVER=http://localhost:#{port} "

      _ ->
        ""
    end
  rescue
    # Endpoint not started (local mode, no server)
    _ -> ""
  end

  defp gitf_binary_path(gitf_root) do
    local_bin = Path.join(gitf_root, "gitf")

    if File.exists?(local_bin) do
      local_bin
    else
      "gitf"
    end
  end
end
