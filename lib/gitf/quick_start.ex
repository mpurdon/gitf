defmodule GiTF.QuickStart do
  @moduledoc """
  Quick start wizard for new section projects.

  Detects the current environment and suggests optimal setup. The quick
  init path auto-discovers git repositories in the target directory and
  registers them as combs, saving the user from manual `gitf sector add`
  invocations.

  This is a pure orchestration module -- no process state. It composes
  `GiTF.Init`, `GiTF.Comb`, and `GiTF.Git` to deliver a streamlined
  first-time experience.
  """

  @doc """
  Detects the current environment and returns a map of relevant facts.

  Inspects the target directory (defaults to CWD) for git repos, tool
  availability, and existing section state.
  """
  @spec detect_environment(String.t()) :: map()
  def detect_environment(path \\ ".") do
    expanded = Path.expand(path)

    %{
      path: expanded,
      has_git: has_git?(),
      has_claude: has_claude?(),
      is_git_repo: GiTF.Git.repo?(expanded),
      is_section: is_section?(expanded),
      git_repos: find_git_repos(expanded)
    }
  end

  @doc """
  Streamlined initialization that auto-discovers and registers combs.

  1. Initializes the section at the given path (with force if already exists)
  2. Detects git repos in immediate subdirectories
  3. Registers each as a comb
  4. Returns a summary of what was set up

  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec quick_init(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def quick_init(path, opts \\ []) do
    expanded = Path.expand(path)
    force? = Keyword.get(opts, :force, false)

    with {:ok, section_path} <- GiTF.Init.init(expanded, force: force?) do
      env = detect_environment(expanded)
      registered_combs = register_discovered_repos(env.git_repos)

      summary = %{
        section_path: section_path,
        environment: env,
        combs_registered: registered_combs
      }

      {:ok, summary}
    end
  end

  @doc """
  Generates a CLAUDE.md for a comb that includes section-specific instructions.

  The generated markdown tells a ghost how to communicate with the queen
  and other ghosts via waggle messages.
  """
  @spec generate_comb_claude_md(String.t(), String.t()) :: String.t()
  def generate_comb_claude_md(comb_name, comb_path) do
    """
    # #{comb_name} - GiTF Worker Instructions

    You are a ghost working on the **#{comb_name}** codebase.
    Your workspace is at: `#{comb_path}`

    ## Communication

    Use waggle messages to communicate with the queen and other ghosts:

    ```bash
    # Report job completion
    section waggle send --to queen --subject "job_complete" --body "Summary of what you did"

    # Report a blocker
    section waggle send --to queen --subject "job_blocked" --body "What is blocking you"

    # Send a message to another ghost
    section waggle send --to <ghost-id> --subject "question" --body "Your question"

    # Check for new messages
    section waggle list --to <your-ghost-id>
    ```

    ## Rules

    - Complete your assigned job and nothing else.
    - Do NOT modify files outside your worktree at `#{comb_path}`.
    - When done, always notify the queen.
    - If blocked, notify the queen immediately rather than guessing.
    - Keep your commits focused and well-described.
    """
  end

  # -- Private helpers -------------------------------------------------------

  defp has_git? do
    case GiTF.Git.git_version() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp has_claude? do
    case GiTF.Runtime.Models.find_executable() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp is_section?(path) do
    File.dir?(Path.join(path, ".gitf"))
  end

  defp find_git_repos(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(&GiTF.Git.repo?/1)

      {:error, _} ->
        []
    end
  end

  defp register_discovered_repos(repo_paths) do
    Enum.reduce(repo_paths, [], fn repo_path, acc ->
      name = Path.basename(repo_path)

      case GiTF.Comb.add(repo_path, name: name) do
        {:ok, comb} -> [{:ok, comb.name} | acc]
        {:error, _reason} -> [{:error, name} | acc]
      end
    end)
    |> Enum.reverse()
  end
end
