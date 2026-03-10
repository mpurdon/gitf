defmodule Hive.GitHub do
  @moduledoc """
  GitHub integration for creating PRs and managing issues.

  Uses Req HTTP client to interact with the GitHub API.
  Pure context module -- no process state.
  """

  require Logger

  @api_base "https://api.github.com"

  @doc """
  Creates a GitHub PR for a cell's branch.

  Returns `{:ok, pr_url}` or `{:error, reason}`.
  """
  @spec create_pr(Hive.Schema.Comb.t(), Hive.Schema.Cell.t(), Hive.Schema.Job.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_pr(comb, cell, job) do
    with {:ok, client} <- client(comb) do
      body = %{
        title: job.title,
        head: cell.branch,
        base: detect_default_branch(comb),
        body: "Automated PR from Hive bee.\n\nJob: #{job.id}\n#{job.description || ""}"
      }

      case Req.post(client,
             url: "/repos/#{comb.github_owner}/#{comb.github_repo}/pulls",
             json: body
           ) do
        {:ok, %{status: status, body: resp}} when status in [201, 200] ->
          {:ok, resp["html_url"]}

        {:ok, %{status: 422, body: %{"errors" => [%{"message" => msg} | _]}}} ->
          {:error, "PR already exists or validation failed: #{msg}"}

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Closes a GitHub issue by number."
  @spec close_issue(Hive.Schema.Comb.t(), integer()) :: :ok | {:error, term()}
  def close_issue(comb, issue_number) do
    with {:ok, client} <- client(comb) do
      case Req.patch(client,
             url: "/repos/#{comb.github_owner}/#{comb.github_repo}/issues/#{issue_number}",
             json: %{state: "closed"}
           ) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Creates a GitHub issue."
  @spec create_issue(Hive.Schema.Comb.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_issue(comb, title, body) do
    with {:ok, client} <- client(comb) do
      case Req.post(client,
             url: "/repos/#{comb.github_owner}/#{comb.github_repo}/issues",
             json: %{title: title, body: body}
           ) do
        {:ok, %{status: 201, body: resp}} ->
          {:ok, resp}

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Lists open issues for a comb."
  @spec list_issues(Hive.Schema.Comb.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_issues(comb, opts \\ []) do
    with {:ok, client} <- client(comb) do
      state = Keyword.get(opts, :state, "open")

      case Req.get(client,
             url: "/repos/#{comb.github_owner}/#{comb.github_repo}/issues",
             params: [state: state, per_page: 30]
           ) do
        {:ok, %{status: 200, body: issues}} ->
          {:ok, issues}

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Adds a comment to an issue or PR."
  @spec add_comment(Hive.Schema.Comb.t(), integer(), String.t()) :: :ok | {:error, term()}
  def add_comment(comb, issue_number, body) do
    with {:ok, client} <- client(comb) do
      case Req.post(client,
             url:
               "/repos/#{comb.github_owner}/#{comb.github_repo}/issues/#{issue_number}/comments",
             json: %{body: body}
           ) do
        {:ok, %{status: 201}} ->
          :ok

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Builds a Req client with GitHub auth."
  @spec client(Hive.Schema.Comb.t()) :: {:ok, Req.Request.t()} | {:error, :no_github_config}
  def client(comb) do
    if Map.get(comb, :github_owner) && Map.get(comb, :github_repo) do
      token = github_token()

      headers =
        [accept: "application/vnd.github+json"]
        |> maybe_add_auth(token)

      {:ok, Req.new(base_url: @api_base, headers: headers)}
    else
      {:error, :no_github_config}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp github_token do
    # Check env var first, then config
    case System.get_env("GITHUB_TOKEN") do
      nil -> read_token_from_config()
      "" -> read_token_from_config()
      token -> token
    end
  end

  defp read_token_from_config do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        config_path = Path.join([hive_root, ".hive", "config.toml"])

        case Hive.Config.read_config(config_path) do
          {:ok, config} ->
            token = get_in(config, ["github", "token"])
            if token && token != "", do: token, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, token), do: [{"authorization", "Bearer #{token}"} | headers]

  defp detect_default_branch(comb) do
    path = Map.get(comb, :path)

    if path && File.dir?(path) do
      case Hive.Git.safe_cmd( ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
             cd: path,
             stderr_to_stdout: true
           ) do
        {branch, 0} -> branch |> String.trim() |> String.replace("origin/", "")
        _ -> "main"
      end
    else
      "main"
    end
  end
end
