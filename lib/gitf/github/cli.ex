defmodule GiTF.GitHub.CLI do
  @moduledoc """
  Typed wrapper around the `gh` CLI for outcome tracking.

  Every call runs inside `Task.Supervisor.async_nolink` with a 15s timeout
  and a `:brutal_kill` shutdown, mirroring the orchestrator's existing
  `verify_pr_url/3` pattern (`lib/gitf/major/orchestrator.ex:2199`).

  Errors are classified so the tracker can decide whether to retry:

    * `{:error, :transient}` — network glitch or 5xx; retry on next tick.
    * `{:error, :permanent}` — 404/auth; stop tracking.
    * `{:error, :timeout}` — gh itself hung; treated as transient.
  """

  require Logger

  @timeout_ms 15_000
  @create_pr_timeout_ms 30_000

  @type pr_details :: %{
          state: String.t(),
          merged: boolean(),
          merged_at: String.t() | nil,
          closed_at: String.t() | nil,
          title: String.t() | nil,
          reviews: [map()],
          status_check_rollup: [map()]
        }

  @type review :: %{
          author: String.t() | nil,
          state: String.t(),
          submitted_at: String.t() | nil,
          body: String.t() | nil
        }

  @type error_class :: :transient | :permanent | :timeout

  @doc """
  Fetches the core PR fields via `gh pr view --json ...`.

  `repo_path` is used as the cwd so `gh` picks up the correct remote.
  """
  @spec pr_details(String.t(), String.t()) :: {:ok, pr_details()} | {:error, error_class()}
  def pr_details(repo_path, pr_url) when is_binary(repo_path) and is_binary(pr_url) do
    fields = "state,merged,mergedAt,closedAt,title,reviews,statusCheckRollup"

    case run_gh(["pr", "view", pr_url, "--json", fields], repo_path) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, data} ->
            {:ok,
             %{
               state: Map.get(data, "state"),
               merged: Map.get(data, "merged", false),
               merged_at: Map.get(data, "mergedAt"),
               closed_at: Map.get(data, "closedAt"),
               title: Map.get(data, "title"),
               reviews: normalize_reviews(Map.get(data, "reviews", [])),
               status_check_rollup: Map.get(data, "statusCheckRollup") || []
             }}

          {:error, _} ->
            {:error, :transient}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Lists recent workflow runs on the main branch. Used by post-merge CI
  status polling. Returns the raw decoded list from `gh run list --json`.
  """
  @spec main_branch_runs(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, error_class()}
  def main_branch_runs(repo_path, limit \\ 5) when is_binary(repo_path) and is_integer(limit) do
    # Resolve the actual default branch — hardcoding "main" made master
    # repos read as eternally-green (gh returns [] with exit 0).
    branch =
      case GiTF.Sync.detect_main_branch(repo_path) do
        {:ok, b} -> b
        _ -> "main"
      end

    args = [
      "run",
      "list",
      "--branch",
      branch,
      "--limit",
      Integer.to_string(limit),
      "--json",
      "conclusion,status,createdAt"
    ]

    case run_gh(args, repo_path) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, runs} when is_list(runs) -> {:ok, runs}
          _ -> {:error, :transient}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates a pull request via `gh pr create`. Returns `{:ok, url}` on
  success, `{:error, output}` on a non-zero exit (the first 200 chars
  of combined stderr+stdout), or `{:error, "gh pr create timed out"}`
  if the call doesn't return inside the timeout. Unlike `pr_details/2`
  and `main_branch_runs/2`, the error here is a string rather than an
  `error_class()` atom because `Publish` needs the literal output to
  classify transient vs. permanent gh failures via
  `transient_gh_error?/1` (rate-limit / 5xx / timeout substrings).
  """
  @spec create_pr(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def create_pr(repo_path, branch, base, title, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @create_pr_timeout_ms)

    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd(
          "gh",
          ["pr", "create", "--head", branch, "--base", base, "--title", title, "--body", body],
          cd: repo_path,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        # stderr is merged in, and gh prints notices/upgrade nags there —
        # extract the PR URL rather than trusting the whole blob.
        case Regex.run(~r{https://github\.com/[^/\s]+/[^/\s]+/pull/\d+}, output) do
          [url] -> {:ok, url}
          _ -> {:error, "gh pr create succeeded but no PR URL in output: #{String.slice(output, 0, 200)}"}
        end

      {:ok, {output, _}} ->
        {:error, String.slice(output, 0, 200)}

      nil ->
        {:error, "gh pr create timed out after #{div(timeout, 1_000)}s"}
    end
  end

  # -- Internal --------------------------------------------------------------

  defp run_gh(args, repo_path) do
    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, _nonzero}} ->
        {:error, classify_output(output)}

      {:exit, reason} ->
        Logger.debug("GitHub.CLI exited: #{inspect(reason)}")
        {:error, :transient}

      nil ->
        {:error, :timeout}
    end
  end

  # Heuristic classification: hard 404/auth errors are permanent; anything
  # else (rate limit, transient network, ambiguous failure) is retried.
  defp classify_output(output) when is_binary(output) do
    lower = String.downcase(output)

    cond do
      String.contains?(lower, "authentication") -> auth_aware_permanent()
      String.contains?(lower, "authorization") -> auth_aware_permanent()
      String.contains?(lower, "not found") -> auth_aware_permanent()
      String.contains?(lower, "could not resolve to") -> auth_aware_permanent()
      String.contains?(lower, "http 404") -> auth_aware_permanent()
      String.contains?(lower, "no pull requests") -> :permanent
      true -> :transient
    end
  end

  defp classify_output(_), do: :transient

  # GitHub 404s private repos when the token is expired/scope-less, so a
  # "not found" is only trustworthy while auth works. With broken auth,
  # classify :transient (retry after the operator fixes the token) and
  # alert — the old behavior permanently stopped outcome tracking.
  defp auth_aware_permanent do
    if gh_auth_ok?() do
      :permanent
    else
      GiTF.Observability.Alerts.dispatch_webhook(
        :github_auth_broken,
        "gh auth check failed — GitHub 404s may be auth errors; outcome tracking degraded until the token is fixed",
        dedup_key: "github_auth_broken"
      )

      :transient
    end
  end

  # Cached for 5 minutes — one subprocess per window, not per classify.
  defp gh_auth_ok? do
    case :persistent_term.get({__MODULE__, :auth_ok}, nil) do
      {ok?, checked_at} ->
        if System.monotonic_time(:second) - checked_at < 300 do
          ok?
        else
          check_and_cache_auth()
        end

      nil ->
        check_and_cache_auth()
    end
  end

  defp check_and_cache_auth do
    ok? =
      case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end

    :persistent_term.put({__MODULE__, :auth_ok}, {ok?, System.monotonic_time(:second)})
    ok?
  rescue
    _ -> true
  end

  defp normalize_reviews(reviews) when is_list(reviews) do
    Enum.map(reviews, fn r ->
      %{
        author:
          case Map.get(r, "author") do
            %{"login" => login} -> login
            login when is_binary(login) -> login
            _ -> nil
          end,
        state: Map.get(r, "state") || "COMMENTED",
        submitted_at: Map.get(r, "submittedAt"),
        body: Map.get(r, "body")
      }
    end)
  end

  defp normalize_reviews(_), do: []
end
