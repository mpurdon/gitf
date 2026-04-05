defmodule GiTF.GitHub do
  @moduledoc """
  GitHub integration for creating PRs and managing issues.

  Uses Req HTTP client to interact with the GitHub API.
  Pure context module -- no process state.
  """

  require Logger

  @api_base "https://api.github.com"

  @doc """
  Creates a GitHub PR for a shell's branch.

  Returns `{:ok, pr_url}` or `{:error, reason}`.
  """
  @spec create_pr(GiTF.Schema.Sector.t(), GiTF.Schema.Shell.t(), GiTF.Schema.Op.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_pr(sector, shell, op) do
    with {:ok, client} <- client(sector) do
      body = %{
        title: op.title,
        head: shell.branch,
        base: detect_default_branch(sector),
        body: "Automated PR from GiTF ghost.\n\nJob: #{op.id}\n#{op.description || ""}"
      }

      case Req.post(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls",
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
  @spec close_issue(GiTF.Schema.Sector.t(), integer()) :: :ok | {:error, term()}
  def close_issue(sector, issue_number) do
    with {:ok, client} <- client(sector) do
      case Req.patch(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/issues/#{issue_number}",
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
  @spec create_issue(GiTF.Schema.Sector.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_issue(sector, title, body) do
    with {:ok, client} <- client(sector) do
      case Req.post(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/issues",
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

  @doc "Lists open issues for a sector."
  @spec list_issues(GiTF.Schema.Sector.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_issues(sector, opts \\ []) do
    with {:ok, client} <- client(sector) do
      state = Keyword.get(opts, :state, "open")

      case Req.get(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/issues",
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

  @doc """
  Creates a mission from a GitHub issue.

  Fetches the issue details, creates a mission with the issue title as the goal
  and the issue body as context, and optionally starts it immediately.

  ## Options

    * `:quick` - use fast path (single ghost, no pipeline). Default: false
    * `:start` - start the mission immediately. Default: true

  Returns `{:ok, mission}` or `{:error, reason}`.
  """
  @spec create_mission_from_issue(map(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_mission_from_issue(sector, issue_number, opts \\ []) do
    with {:ok, client} <- client(sector),
         {:ok, issue} <- fetch_issue(client, sector, issue_number) do
      title = issue["title"] || "Issue ##{issue_number}"
      body = issue["body"] || ""
      labels = Enum.map(issue["labels"] || [], & &1["name"]) |> Enum.join(", ")

      goal =
        """
        #{title}

        #{body}
        #{if labels != "", do: "\nLabels: #{labels}", else: ""}
        GitHub Issue: #{issue["html_url"]}
        """
        |> String.trim()

      attrs = %{
        goal: goal,
        name: "GH-#{issue_number}: #{String.slice(title, 0, 60)}",
        sector_id: sector.id
      }

      case GiTF.Missions.create(attrs) do
        {:ok, mission} ->
          quick = Keyword.get(opts, :quick, false)
          start = Keyword.get(opts, :start, true)

          if start do
            start_opts = if quick, do: [force_fast_path: true], else: []
            GiTF.Major.Orchestrator.start_quest(mission.id, start_opts)
          end

          {:ok, mission}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_issue(client, sector, issue_number) do
    case Req.get(client,
           url: "/repos/#{sector.github_owner}/#{sector.github_repo}/issues/#{issue_number}"
         ) do
      {:ok, %{status: 200, body: issue}} ->
        {:ok, issue}

      {:ok, %{status: 404}} ->
        {:error, :issue_not_found}

      {:ok, %{status: status, body: resp}} ->
        {:error, "GitHub API error #{status}: #{inspect(resp)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Adds a comment to an issue or PR."
  @spec add_comment(GiTF.Schema.Sector.t(), integer(), String.t()) :: :ok | {:error, term()}
  def add_comment(sector, issue_number, body) do
    with {:ok, client} <- client(sector) do
      case Req.post(client,
             url:
               "/repos/#{sector.github_owner}/#{sector.github_repo}/issues/#{issue_number}/comments",
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

  @doc "Lists repositories for the authenticated user."
  @spec list_repos(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_repos(opts \\ []) do
    token = github_token()

    if is_nil(token) do
      {:error, :no_github_token}
    else
      headers = [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer #{token}"}
      ]

      sort = Keyword.get(opts, :sort, "updated")
      per_page = Keyword.get(opts, :per_page, 30)

      case Req.get(Req.new(base_url: @api_base, headers: headers),
             url: "/user/repos",
             params: [sort: sort, per_page: per_page, type: "owner"]
           ) do
        {:ok, %{status: 200, body: repos}} ->
          {:ok,
           Enum.map(repos, fn r ->
             %{
               full_name: r["full_name"],
               name: r["name"],
               clone_url: r["clone_url"],
               ssh_url: r["ssh_url"],
               html_url: r["html_url"],
               description: r["description"],
               private: r["private"],
               language: r["language"],
               updated_at: r["updated_at"]
             }
           end)}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Builds a Req client with GitHub auth."
  @spec client(GiTF.Schema.Sector.t()) :: {:ok, Req.Request.t()} | {:error, :no_github_config}
  def client(sector) do
    if Map.get(sector, :github_owner) && Map.get(sector, :github_repo) do
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
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        config_path = Path.join([gitf_root, ".gitf", "config.toml"])

        case GiTF.Config.read_config(config_path) do
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

  defp detect_default_branch(sector) do
    path = Map.get(sector, :path)

    if path && File.dir?(path) do
      case GiTF.Git.safe_cmd(["symbolic-ref", "refs/remotes/origin/HEAD", "--short"],
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
