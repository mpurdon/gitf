defmodule GiTF.Git do
  @moduledoc """
  Thin wrapper around `git` CLI operations.

  Every function delegates to `System.cmd/3` rather than shelling out through
  `os:cmd/1`, giving us proper exit-code handling and stderr capture. This
  module contains no state -- it is a collection of pure utility functions that
  transform arguments into git results.

  All git commands run with a 60-second timeout to prevent hangs.
  """

  @git_timeout_ms 60_000

  @doc """
  Clones a git repository into `destination`.

  Returns `{:ok, destination}` on success or `{:error, message}` on failure.
  """
  @spec clone(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def clone(repo_url, destination) do
    case safe_cmd(["clone", repo_url, destination], stderr_to_stdout: true) do
      {_output, 0} -> {:ok, destination}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns the installed git version string, e.g. `"2.43.0"`.

  Returns `{:ok, version}` or `{:error, :git_not_found}`.
  """
  @spec git_version() :: {:ok, String.t()} | {:error, :git_not_found}
  def git_version do
    case safe_cmd(["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version =
          output
          |> String.trim()
          |> String.replace(~r/^git version\s*/, "")

        {:ok, version}

      _ ->
        {:error, :git_not_found}
    end
  rescue
    ErlangError -> {:error, :git_not_found}
  end

  @doc """
  Checks whether `path` is inside a git repository.

  Returns `true` if git recognizes the path as a work tree, `false` otherwise.
  """
  @spec repo?(String.t()) :: boolean()
  def repo?(path) do
    case safe_cmd(["rev-parse", "--is-inside-work-tree"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Determines whether a string refers to a local filesystem path or a remote URL.

  Local paths start with `/`, `./`, `~`, or lack any URI scheme indicator
  (no `://` and no `:`).

  ## Examples

      iex> GiTF.Git.local_path?("/home/user/repo")
      true

      iex> GiTF.Git.local_path?("./my-repo")
      true

      iex> GiTF.Git.local_path?("https://github.com/user/repo.git")
      false

      iex> GiTF.Git.local_path?("git@github.com:user/repo.git")
      false
  """
  @spec local_path?(String.t()) :: boolean()
  def local_path?(path_or_url) do
    cond do
      String.starts_with?(path_or_url, "/") -> true
      String.starts_with?(path_or_url, "./") -> true
      String.starts_with?(path_or_url, "../") -> true
      String.starts_with?(path_or_url, "~") -> true
      String.contains?(path_or_url, "://") -> false
      String.contains?(path_or_url, ":") -> false
      true -> true
    end
  end

  # -- Worktree operations ---------------------------------------------------

  @doc """
  Creates a new git worktree at `worktree_path` on a new branch.

  Runs `git worktree add <worktree_path> -b <branch>` from the given
  `repo_path`. Returns `{:ok, worktree_path}` on success.
  """
  @spec worktree_add(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def worktree_add(repo_path, worktree_path, branch) do
    case safe_cmd(["worktree", "add", worktree_path, "-b", branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, worktree_path}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Removes a git worktree.

  Runs `git worktree remove <worktree_path>` from the given `repo_path`.
  Pass `force: true` in opts to use `--force`.

  Returns `:ok` on success.
  """
  @spec worktree_remove(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def worktree_remove(repo_path, worktree_path, opts \\ []) do
    args =
      if Keyword.get(opts, :force, false),
        do: ["worktree", "remove", "--force", worktree_path],
        else: ["worktree", "remove", worktree_path]

    case safe_cmd(args, cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Lists all worktrees for a repository by parsing `git worktree list --porcelain`.

  Returns a list of maps, each containing `:path`, `:head`, and `:branch` keys.
  The main worktree has branch set to its full ref; detached worktrees have
  `:branch` set to `nil`.
  """
  @spec worktree_list(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def worktree_list(repo_path) do
    case safe_cmd(["worktree", "list", "--porcelain"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        worktrees = parse_worktree_porcelain(output)
        {:ok, worktrees}

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end

  @doc """
  Deletes a local git branch.

  Runs `git branch -D <branch_name>` from `repo_path`.
  Returns `:ok` on success.
  """
  @spec branch_delete(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_delete(repo_path, branch_name) do
    case safe_cmd(["branch", "-D", branch_name],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc "Returns the current branch name."
  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def current_branch(repo_path) do
    case safe_cmd(["rev-parse", "--abbrev-ref", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc "Checks out a branch."
  @spec checkout(String.t(), String.t()) :: :ok | {:error, String.t()}
  def checkout(repo_path, branch) do
    case safe_cmd(["checkout", branch], cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc "Syncs a branch into the current branch."
  @spec sync(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def sync(repo_path, branch, opts \\ []) do
    args =
      if Keyword.get(opts, :no_ff, false),
        do: ["sync", "--no-ff", branch],
        else: ["sync", branch]

    case safe_cmd(args, cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc "Checks whether a local branch exists."
  @spec branch_exists?(String.t(), String.t()) :: boolean()
  def branch_exists?(repo_path, branch) do
    case safe_cmd(["rev-parse", "--verify", "refs/heads/#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  @doc "Creates a new branch from a base ref."
  @spec branch_create(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_create(repo_path, branch, base) do
    case safe_cmd(["checkout", "-b", branch, base],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Prunes stale worktree metadata.

  Runs `git worktree prune` from `repo_path` to clean up
  worktree entries whose directories have been manually removed.
  Returns `:ok` on success.
  """
  @spec worktree_prune(String.t()) :: :ok | {:error, String.t()}
  def worktree_prune(repo_path) do
    case safe_cmd(["worktree", "prune"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  # -- Sparse checkout operations ----------------------------------------------

  @doc """
  Initializes sparse checkout in cone mode for the given repository.

  Runs `git sparse-checkout init --cone` from `repo_path`.
  Returns `:ok` on success.
  """
  @spec sparse_checkout_init(String.t()) :: :ok | {:error, String.t()}
  def sparse_checkout_init(repo_path) do
    case safe_cmd(["sparse-checkout", "init", "--cone"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Sets the sparse checkout patterns for a repository.

  Runs `git sparse-checkout set <patterns>` from `repo_path`.
  Patterns is a list of directory paths to include.
  Returns `:ok` on success.
  """
  @spec sparse_checkout_set(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def sparse_checkout_set(repo_path, patterns) do
    case safe_cmd(["sparse-checkout", "set" | patterns],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Rolls back a repository to its last committed state.
  Runs `git reset --hard HEAD` and `git clean -fd`.
  """
  @spec rollback(String.t()) :: :ok | {:error, String.t()}
  def rollback(repo_path) do
    case safe_cmd(["reset", "--hard", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {_, 0} ->
        case safe_cmd(["clean", "-fd"], cd: repo_path, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _} -> {:error, "clean failed: #{String.trim(output)}"}
        end

      {output, _} ->
        {:error, "reset failed: #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the full SHA of HEAD in a repo or worktree.
  """
  @spec head_sha(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def head_sha(repo_path), do: rev_parse(repo_path, "HEAD")

  @doc """
  Resolves a ref to its full SHA via `git rev-parse --verify`.
  """
  @spec rev_parse(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def rev_parse(repo_path, ref) do
    case safe_cmd(["rev-parse", "--verify", ref], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns the merge-base of two refs.
  """
  @spec merge_base(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def merge_base(repo_path, ref_a, ref_b) do
    case safe_cmd(["merge-base", ref_a, ref_b], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns true if `ancestor` is an ancestor commit of `descendant`.
  Returns false on any non-zero exit (including "not an ancestor" and errors).
  """
  @spec ancestor?(String.t(), String.t(), String.t()) :: boolean()
  def ancestor?(repo_path, ancestor, descendant) do
    case safe_cmd(["merge-base", "--is-ancestor", ancestor, descendant],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Fetches updates from a remote. Returns `:ok` or `{:error, reason}`.
  Intended to be called best-effort; callers should not fail on `:error`.
  """
  @spec fetch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def fetch(repo_path, remote \\ "origin") do
    case safe_cmd(["fetch", "--quiet", remote], cd: repo_path, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Lists files changed between two refs (`git diff --name-only <from>..<to>`).
  """
  @spec changed_files_between(String.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def changed_files_between(repo_path, from_ref, to_ref) do
    case safe_cmd(["diff", "--name-only", "#{from_ref}..#{to_ref}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Counts commits in a range (`git rev-list --count <range>`).
  """
  @spec count_commits(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def count_commits(repo_path, range) do
    case safe_cmd(["rev-list", "--count", range], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {n, _} -> {:ok, n}
          _ -> {:error, "unparseable count"}
        end

      {output, _} ->
        {:error, String.trim(output)}
    end
  end

  @doc """
  Runs a git command with a timeout to prevent hangs.

  Wraps `System.cmd/3` in a Task that is killed after `@git_timeout_ms`.
  Returns `{output, exit_code}` or `{"git command timed out", 1}`.
  """
  def safe_cmd(args, opts \\ []) do
    task = Task.async(fn -> System.cmd("/usr/bin/git", args, opts) end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, result} -> result
      nil -> {"git command timed out after #{div(@git_timeout_ms, 1000)}s", 1}
    end
  end

  # -- Private: porcelain parser ---------------------------------------------

  defp parse_worktree_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_worktree_block/1)
  end

  defp parse_worktree_block(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{path: nil, head: nil, branch: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "worktree ") ->
          %{acc | path: String.trim_leading(line, "worktree ")}

        String.starts_with?(line, "HEAD ") ->
          %{acc | head: String.trim_leading(line, "HEAD ")}

        String.starts_with?(line, "branch ") ->
          %{acc | branch: String.trim_leading(line, "branch ")}

        line == "detached" ->
          acc

        line == "bare" ->
          acc

        true ->
          acc
      end
    end)
  end
end
