defmodule GiTF.Runtime.Loadout do
  @moduledoc """
  Tool definitions for the agent loop.

  Defines the tools that LLM agents can invoke during agentic execution.
  Each tool wraps a filesystem, shell, or git operation scoped to a
  working directory. Paths are validated to prevent directory traversal.

  ## Tool Sets

  - `:standard` — Full read/write tools for implementation ghosts
  - `:readonly` — Read-only tools for phase/validation ghosts
  - `:major` — Standard tools + orchestration tools
  """

  require Logger

  @bash_timeout_ms 120_000

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns a list of ReqLLM.Tool structs for the given tool set.

  ## Options

    * `:working_dir` — required, the directory to scope operations to
    * `:tool_set` — `:standard` (default), `:readonly`, or `:major`
  """
  @spec tools(keyword()) :: [ReqLLM.Tool.t()]
  def tools(opts \\ []) do
    working_dir = Keyword.fetch!(opts, :working_dir)
    tool_set = Keyword.get(opts, :tool_set, :standard)
    include_dynamic = Keyword.get(opts, :include_dynamic, false)

    static =
      case tool_set do
        :readonly -> readonly_tools(working_dir)
        :major -> standard_tools(working_dir) ++ queen_tools()
        _ -> standard_tools(working_dir)
      end

    if include_dynamic do
      static ++ GiTF.Runtime.Loadout.DynamicTools.discover(opts)
    else
      static
    end
  end

  # -- Readonly Tools ----------------------------------------------------------

  defp readonly_tools(working_dir) do
    [
      build_tool(
        "read_file",
        "Read a file's contents",
        [
          path: [type: :string, required: true, doc: "Relative path to the file"]
        ],
        &read_file(&1, working_dir)
      ),
      build_tool(
        "list_directory",
        "List files and directories",
        [
          path: [type: :string, doc: "Relative path to list (default: working directory root)"]
        ],
        &list_directory(&1, working_dir)
      ),
      build_tool(
        "search_files",
        "Search for text patterns in files using grep",
        [
          pattern: [type: :string, required: true, doc: "Search pattern (regex)"],
          path: [type: :string, doc: "Relative directory to search in (default: .)"],
          glob: [type: :string, doc: "File glob filter (e.g. \"*.ex\")"]
        ],
        &search_files(&1, working_dir)
      ),
      build_tool(
        "git_diff",
        "Show git diff",
        [
          ref: [type: :string, doc: "Git ref to diff against (default: HEAD)"]
        ],
        &git_diff(&1, working_dir)
      ),
      build_tool("git_status", "Show git status", [], &git_status(&1, working_dir)),
      build_tool(
        "github_issue",
        "Fetch a GitHub issue or PR by repo and number",
        [
          repo: [type: :string, required: true, doc: "Repository in owner/repo format"],
          number: [type: :string, required: true, doc: "Issue or PR number"],
          type: [type: :string, doc: "Type: 'issue' (default) or 'pr'"]
        ],
        &github_fetch/1
      ),
      build_tool(
        "fetch_url",
        "Fetch content from a URL (for docs, APIs, etc.)",
        [
          url: [type: :string, required: true, doc: "The URL to fetch"]
        ],
        &fetch_url/1
      )
    ]
  end

  # -- Standard Tools ----------------------------------------------------------

  defp standard_tools(working_dir) do
    readonly_tools(working_dir) ++
      [
        build_tool(
          "write_file",
          "Create or overwrite a file with the given content",
          [
            path: [type: :string, required: true, doc: "Relative path to the file"],
            content: [type: :string, required: true, doc: "File content to write"]
          ],
          &write_file(&1, working_dir)
        ),
        build_tool(
          "run_bash",
          "Execute a bash command",
          [
            command: [type: :string, required: true, doc: "The bash command to execute"],
            timeout_ms: [type: :pos_integer, doc: "Timeout in milliseconds (default: 120000)"]
          ],
          &run_bash(&1, working_dir)
        ),
        build_tool(
          "git_add",
          "Stage files for commit",
          [
            paths: [type: :string, required: true, doc: "Space-separated file paths to stage"]
          ],
          &git_add(&1, working_dir)
        ),
        build_tool(
          "git_commit",
          "Create a git commit",
          [
            message: [type: :string, required: true, doc: "Commit message"]
          ],
          &git_commit(&1, working_dir)
        )
      ]
  end

  # -- Major Tools -------------------------------------------------------------

  defp queen_tools do
    [
      build_tool("list_quests", "List all active missions and their statuses", [], fn _args ->
        list_quests()
      end),
      build_tool("list_bees", "List all active ghosts and their statuses", [], fn _args ->
        list_bees()
      end),
      build_tool("check_costs", "Check total cost summary for the section", [], fn _args ->
        check_costs()
      end)
    ]
  end

  # -- Tool Implementations ----------------------------------------------------

  defp read_file(args, working_dir) do
    path = resolve_path(args["path"] || args[:path], working_dir)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:ok, "Error reading file: #{inspect(reason)}"}
    end
  end

  defp write_file(args, working_dir) do
    path = resolve_path(args["path"] || args[:path], working_dir)
    content = args["content"] || args[:content] || ""

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.write(path, content) do
      :ok -> {:ok, "File written successfully: #{args["path"] || args[:path]}"}
      {:error, reason} -> {:ok, "Error writing file: #{inspect(reason)}"}
    end
  end

  defp list_directory(args, working_dir) do
    rel_path = args["path"] || args[:path] || "."
    path = resolve_path(rel_path, working_dir)

    case File.ls(path) do
      {:ok, entries} ->
        listing = Enum.sort(entries) |> Enum.join("\n")
        {:ok, listing}

      {:error, reason} ->
        {:ok, "Error listing directory: #{inspect(reason)}"}
    end
  end

  defp search_files(args, working_dir) do
    pattern = args["pattern"] || args[:pattern]
    rel_path = args["path"] || args[:path] || "."
    glob = args["glob"] || args[:glob]
    path = resolve_path(rel_path, working_dir)

    grep_args = ["--recursive", "--line-number", "--color=never"]
    grep_args = if glob, do: grep_args ++ ["--include=#{glob}"], else: grep_args
    grep_args = grep_args ++ [pattern, path]

    task =
      Task.async(fn ->
        System.cmd("grep", grep_args, stderr_to_stdout: true)
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, 5_000) do
      {:ok, {output, 0}} -> {:ok, String.slice(output, 0, 10_000)}
      {:ok, {output, 1}} -> {:ok, "No matches found.\n#{output}"}
      {:ok, {output, _}} -> {:ok, "Search error: #{String.slice(output, 0, 2_000)}"}
      nil -> {:ok, "Search timed out after 30s"}
    end
  rescue
    e -> {:ok, "Search error: #{Exception.message(e)}"}
  end

  defp run_bash(args, working_dir) do
    command = args["command"] || args[:command]
    timeout = args["timeout_ms"] || args[:timeout_ms] || @bash_timeout_ms

    task =
      Task.async(fn ->
        # Use Sandbox to wrap the command if available
        {cmd, cmd_args, cmd_opts} =
          if GiTF.Sandbox.available?() do
            # When sandboxed, we don't pass host HOME, we rely on sandbox HOME (/tmp or similar)
            GiTF.Sandbox.wrap_command("bash", ["-c", command],
              cd: working_dir,
              env: [{"HOME", "/tmp"}]
            )
          else
            # Fallback for local execution
            {"bash", ["-c", command],
             cd: working_dir, env: [{"HOME", System.get_env("HOME", "/tmp")}]}
          end

        # Ensure output is captured
        cmd_opts = Keyword.put(cmd_opts, :stderr_to_stdout, true)

        System.cmd(cmd, cmd_args, cmd_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, 5_000) do
      {:ok, {output, exit_code}} ->
        result = String.slice(output, 0, 15_000)
        {:ok, "Exit code: #{exit_code}\n#{result}"}

      nil ->
        {:ok, "Command timed out after #{timeout}ms"}
    end
  rescue
    e -> {:ok, "Command error: #{Exception.message(e)}"}
  end

  defp git_diff(args, working_dir) do
    ref = args["ref"] || args[:ref] || "HEAD"

    case GiTF.Git.safe_cmd(["diff", ref], cd: working_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.slice(output, 0, 15_000)}
      {output, _} -> {:ok, "git diff error: #{String.slice(output, 0, 2_000)}"}
    end
  rescue
    e -> {:ok, "git diff error: #{Exception.message(e)}"}
  end

  defp git_status(_args, working_dir) do
    case GiTF.Git.safe_cmd(["status", "--short"], cd: working_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:ok, "git status error: #{output}"}
    end
  rescue
    e -> {:ok, "git status error: #{Exception.message(e)}"}
  end

  defp git_add(args, working_dir) do
    paths = String.split(args["paths"] || args[:paths] || "", " ", trim: true)

    case GiTF.Git.safe_cmd(["add" | paths], cd: working_dir, stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Files staged: #{Enum.join(paths, ", ")}"}
      {output, _} -> {:ok, "git add error: #{output}"}
    end
  rescue
    e -> {:ok, "git add error: #{Exception.message(e)}"}
  end

  defp git_commit(args, working_dir) do
    message = args["message"] || args[:message]

    case GiTF.Git.safe_cmd(["commit", "-m", message], cd: working_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:ok, "git commit error: #{output}"}
    end
  rescue
    e -> {:ok, "git commit error: #{Exception.message(e)}"}
  end

  # -- Major tool implementations -----------------------------------------------

  defp list_quests do
    missions = GiTF.Archive.all(:missions)

    summary =
      Enum.map(missions, fn q ->
        "#{q.id}: #{q.name} (#{q.status}) - #{length(Map.get(q, :ops, []))} ops"
      end)
      |> Enum.join("\n")

    {:ok, if(summary == "", do: "No missions found.", else: summary)}
  rescue
    _ -> {:ok, "Error listing missions"}
  end

  defp list_bees do
    ghosts = GiTF.Archive.all(:ghosts)

    summary =
      Enum.map(ghosts, fn b ->
        "#{b.id}: #{b.name} (#{b.status}) - op: #{b.op_id || "none"}"
      end)
      |> Enum.join("\n")

    {:ok, if(summary == "", do: "No ghosts found.", else: summary)}
  rescue
    _ -> {:ok, "Error listing ghosts"}
  end

  defp check_costs do
    summary = GiTF.Costs.summary()

    {:ok,
     """
     Total cost: $#{Float.round(summary.total_cost, 4)}
     Input tokens: #{summary.total_input_tokens}
     Output tokens: #{summary.total_output_tokens}
     Models: #{summary.by_model |> Map.keys() |> Enum.join(", ")}
     """}
  rescue
    _ -> {:ok, "Error checking costs"}
  end

  # -- External resource tools -------------------------------------------------

  defp github_fetch(args) do
    repo = args["repo"] || args[:repo]
    number = args["number"] || args[:number]
    type = args["type"] || args[:type] || "issue"

    cmd = if type == "pr", do: "pr", else: "issue"

    case System.cmd("gh", [cmd, "view", to_string(number), "--repo", repo],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:ok, "gh #{cmd} view error: #{output}"}
    end
  rescue
    e -> {:ok, "GitHub fetch error: #{Exception.message(e)}"}
  end

  defp fetch_url(args) do
    url = args["url"] || args[:url]

    case Req.get(url, receive_timeout: 10_000, redirect: true, max_redirects: 3) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        text = if is_binary(body), do: body, else: inspect(body)
        {:ok, String.slice(text, 0, 50_000)}

      {:ok, %{status: status}} ->
        {:ok, "HTTP #{status} fetching #{url}"}

      {:error, reason} ->
        {:ok, "Fetch error: #{inspect(reason)}"}
    end
  rescue
    e -> {:ok, "Fetch error: #{Exception.message(e)}"}
  end

  # -- Helpers -----------------------------------------------------------------

  defp build_tool(name, description, schema, callback) do
    opts = [
      name: name,
      description: description,
      callback: callback
    ]

    opts = if schema != [], do: Keyword.put(opts, :parameter_schema, schema), else: opts

    ReqLLM.Tool.new!(opts)
  end

  @doc """
  Resolves a relative path against the working directory, with traversal protection.

  Raises if the resolved path escapes the working directory.
  """
  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(rel_path, working_dir) do
    abs = Path.expand(rel_path, working_dir)
    wd = Path.expand(working_dir)

    # Allow paths within the working directory (worktree)
    # AND within the sector root (parent of ghosts/ directory),
    # since worktrees live inside the sector at <sector>/ghosts/<ghost_id>
    sector_root = find_sector_root(wd)

    allowed =
      String.starts_with?(abs, wd) or
        (sector_root != nil and String.starts_with?(abs, sector_root))

    unless allowed do
      raise "Path traversal detected: #{rel_path} resolves outside #{working_dir}"
    end

    abs
  end

  # Worktrees are at <sector>/ghosts/<ghost_id>. Walk up to find the sector root.
  defp find_sector_root(worktree_path) do
    parts = Path.split(worktree_path)
    ghosts_idx = Enum.find_index(parts, &(&1 == "ghosts"))

    if ghosts_idx && ghosts_idx > 0 do
      parts |> Enum.take(ghosts_idx) |> Path.join()
    else
      nil
    end
  end
end
