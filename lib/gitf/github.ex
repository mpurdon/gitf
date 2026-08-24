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

      # redirect: false — a renamed/transferred repo 301s, and Req would
      # demote the POST to a GET of the PR *list*, yielding {:ok, nil}
      # that callers logged as "PR created". 201 is the only creation.
      case Req.post(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls",
             json: body,
             redirect: false
           ) do
        {:ok, %{status: 201, body: %{"html_url" => url}}} when is_binary(url) ->
          {:ok, url}

        {:ok, %{status: status}} when status in [301, 307, 308] ->
          {:error, "repository moved (HTTP #{status}) — cached owner/repo is stale; re-add or update the sector"}

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

  @doc """
  Fetches the PR fields the outcome tracker needs, over the REST API.

  Replaces the `gh pr view --json` shell-out. `gh` is an independently
  versioned binary whose JSON schema changes underneath us: it removed the
  `merged` field, `--json` rejects the whole request on any unknown field,
  and so every outcome poll failed for days — invisibly, because a CLI
  returns unstructured text that has to be guessed at rather than a status
  code. The REST API is versioned and does not drop response fields.

  Returns the same shape `GiTF.GitHub.CLI.pr_details/2` did, so callers are
  unchanged: `{:ok, details}` or `{:error, :transient | :permanent}`.
  """
  @spec pr_details(GiTF.Schema.Sector.t(), String.t() | integer()) ::
          {:ok, map()} | {:error, :transient | :permanent}
  def pr_details(sector, pr_ref) do
    with number when is_integer(number) <- pr_number(pr_ref),
         {:ok, client} <- client(sector),
         {:ok, pr} <- get_pr(client, sector, number) do
      {:ok,
       %{
         state: pr["state"],
         merged: pr["merged"] == true or not is_nil(pr["merged_at"]),
         merged_at: pr["merged_at"],
         closed_at: pr["closed_at"],
         title: pr["title"],
         # The PR's own head branch. Review follow-ups must build on it, and
         # asking GitHub is authoritative — deriving it from our sync artifact
         # meant a missing artifact could send the work somewhere else.
         head_ref: get_in(pr, ["head", "ref"]),
         # Lets a completion notice tell "I pushed a fix" from "this was
         # already addressed" by comparing the head against what it was when
         # the work was admitted.
         head_sha: get_in(pr, ["head", "sha"]),
         reviews: fetch_reviews(client, sector, number),
         # Only Alerts consumes check state, and it has its own path.
         status_check_rollup: []
       }}
    else
      {:error, :permanent} = err -> err
      {:error, _} -> {:error, :transient}
      nil -> {:error, :permanent}
    end
  end

  defp get_pr(client, sector, number) do
    case Req.get(client,
           url: "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls/#{number}"
         ) do
      {:ok, %{status: 200, body: pr}} -> {:ok, pr}
      # A PR that is gone or forbidden will never resolve by retrying.
      {:ok, %{status: status}} when status in [401, 403, 404] -> {:error, :permanent}
      {:ok, %{status: _}} -> {:error, :transient}
      {:error, _} -> {:error, :transient}
    end
  end

  # Reviews are a separate endpoint. A failure here degrades to "no reviews"
  # rather than failing the whole poll: PR state still matters.
  defp fetch_reviews(client, sector, number) do
    case Req.get(client,
           url: "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls/#{number}/reviews",
           params: [per_page: 100]
         ) do
      {:ok, %{status: 200, body: reviews}} when is_list(reviews) ->
        Enum.map(reviews, fn r ->
          %{
            id: r["id"],
            author: get_in(r, ["user", "login"]),
            # REST uses SCREAMING_CASE for state, as gh did.
            state: r["state"] || "COMMENTED",
            submitted_at: r["submitted_at"],
            body: r["body"]
          }
        end)

      _ ->
        []
    end
  end

  defp pr_number(n) when is_integer(n), do: n

  defp pr_number(ref) when is_binary(ref) do
    case Regex.run(~r{/pull/(\d+)}, ref) do
      [_, n] -> String.to_integer(n)
      _ -> if(Regex.match?(~r/^\d+$/, ref), do: String.to_integer(ref))
    end
  end

  defp pr_number(_), do: nil

  @doc """
  Lists inline review comments on a pull request.

  These are where a change request usually lives: requesting changes via a
  `suggestion` block leaves the review body empty and puts the entire ask in
  a comment anchored to a file and line. A follow-up mission that reads only
  the review body sees nothing at all.

  Returns `{:ok, [%{path:, line:, body:, review_id:, author:, diff_hunk:}]}`.
  """
  @spec list_review_comments(GiTF.Schema.Sector.t(), integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_review_comments(sector, pr_number) do
    with {:ok, client} <- client(sector) do
      case Req.get(client,
             url: "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls/#{pr_number}/comments",
             params: [per_page: 100]
           ) do
        {:ok, %{status: 200, body: comments}} when is_list(comments) ->
          {:ok, Enum.map(comments, &normalize_review_comment/1)}

        {:ok, %{status: status, body: resp}} ->
          {:error, "GitHub API error #{status}: #{inspect(resp)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_review_comment(c) do
    %{
      # Kept so a follow-up can reply IN the thread it answers, where the
      # reviewer can resolve it — a conversation comment is easy to miss.
      id: c["id"],
      path: c["path"],
      # `line` is null on outdated comments; original_line still locates them.
      line: c["line"] || c["original_line"],
      body: c["body"],
      review_id: c["pull_request_review_id"],
      author: get_in(c, ["user", "login"]),
      diff_hunk: c["diff_hunk"]
    }
  end

  @doc """
  Replies inside an existing review-comment thread.

  A reply lands under the comment it answers, so the reviewer sees the
  response next to their own words and can resolve the conversation. A
  top-level comment on the PR does neither — it was posted and missed.
  """
  @spec reply_to_review_comment(GiTF.Schema.Sector.t(), integer(), integer(), String.t()) ::
          :ok | {:error, term()}
  def reply_to_review_comment(sector, pr_number, comment_id, body) do
    with {:ok, client} <- client(sector) do
      case Req.post(client,
             url:
               "/repos/#{sector.github_owner}/#{sector.github_repo}/pulls/#{pr_number}/comments/#{comment_id}/replies",
             json: %{body: body}
           ) do
        {:ok, %{status: 201}} -> :ok
        {:ok, %{status: status, body: resp}} -> {:error, "GitHub API error #{status}: #{inspect(resp)}"}
        {:error, reason} -> {:error, reason}
      end
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

  @doc "Adds a label to an issue (creating the label on the repo if needed)."
  @spec add_label(GiTF.Schema.Sector.t(), integer(), String.t()) :: :ok | {:error, term()}
  def add_label(sector, issue_number, label) do
    with {:ok, client} <- client(sector) do
      case Req.post(client,
             url:
               "/repos/#{sector.github_owner}/#{sector.github_repo}/issues/#{issue_number}/labels",
             json: %{labels: [label]}
           ) do
        {:ok, %{status: status}} when status in [200, 201] -> :ok
        {:ok, %{status: status, body: resp}} -> {:error, "GitHub API error #{status}: #{inspect(resp)}"}
        {:error, reason} -> {:error, reason}
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

  @doc "Returns true if a GitHub token is available (env var or config)."
  @spec has_token?() :: boolean()
  def has_token?, do: github_token() != nil

  @doc "Builds a Req client with GitHub auth."
  @spec client(GiTF.Schema.Sector.t()) :: {:ok, Req.Request.t()} | {:error, :no_github_config}
  def client(sector) do
    cond do
      !(Map.get(sector, :github_owner) && Map.get(sector, :github_repo)) ->
        {:error, :no_github_config}

      github_token() in [nil, ""] ->
        # An anonymous client silently 404s private repos ("issue not
        # found" lies) and burns the 60/hr unauthenticated IP budget —
        # fail loudly instead.
        {:error, :no_github_token}

      true ->
        headers =
          [accept: "application/vnd.github+json"]
          |> maybe_add_auth(github_token())

        {:ok, Req.new(base_url: @api_base, headers: headers)}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp github_token do
    # Resolution order:
    #   1. GITHUB_TOKEN env var
    #   2. <gitf_root>/.gitf/config.toml [github] token
    #   3. `gh auth token` — falls back to gh CLI's keyring if user is
    #      already authenticated there (avoids duplicate token setup).
    cond do
      env = sanitize(System.get_env("GITHUB_TOKEN")) -> env
      cfg = read_token_from_config() -> cfg
      gh = read_token_from_gh_cli() -> gh
      true -> nil
    end
  end

  defp sanitize(nil), do: nil
  defp sanitize(""), do: nil
  defp sanitize(s) when is_binary(s), do: s

  defp read_token_from_gh_cli do
    case System.find_executable("gh") do
      nil ->
        nil

      gh_path ->
        try do
          case System.cmd(gh_path, ["auth", "token"], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
            {token, 0} -> token |> String.trim() |> sanitize()
            _ -> nil
          end
        rescue
          _ -> nil
        end
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
