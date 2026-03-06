defmodule Hive.Plugin.Builtin.ToolProviders.ProjectContext do
  @moduledoc """
  Built-in tool provider that exposes project context tools to agents.

  Provides: `project_info`, `codebase_map`, `dependency_info`.
  """

  use Hive.Plugin, type: :tool_provider

  @skip_dirs ~w(node_modules _build deps .elixir_ls .git .hive build dist __pycache__ target .next)

  @impl true
  def name, do: "project_context"

  @impl true
  def description, do: "Project context tools for agents"

  @impl true
  def tools do
    [
      project_info_tool(),
      codebase_map_tool(),
      dependency_info_tool()
    ]
  end

  # -- project_info ------------------------------------------------------------

  defp project_info_tool do
    ReqLLM.Tool.new!(
      name: "project_info",
      description: "Detect project language, build tool, test framework, and git info from the filesystem.",
      parameter_schema: [
        path: [type: :string, doc: "Project root path (default: current comb)"]
      ],
      callback: &project_info/1
    )
  end

  defp project_info(args) do
    path = resolve_project_path(args["path"] || args[:path])

    info = %{
      path: path,
      language: detect_language(path),
      build_tool: detect_build_tool(path),
      test_dir: detect_test_dir(path),
      git: detect_git_info(path)
    }

    {:ok, format_map(info)}
  rescue
    e -> {:ok, "Error: #{Exception.message(e)}"}
  end

  defp detect_language(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> "elixir"
      File.exists?(Path.join(path, "package.json")) -> "javascript/typescript"
      File.exists?(Path.join(path, "Cargo.toml")) -> "rust"
      File.exists?(Path.join(path, "go.mod")) -> "go"
      File.exists?(Path.join(path, "pyproject.toml")) or File.exists?(Path.join(path, "setup.py")) -> "python"
      File.exists?(Path.join(path, "Gemfile")) -> "ruby"
      true -> "unknown"
    end
  end

  defp detect_build_tool(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> "mix"
      File.exists?(Path.join(path, "package.json")) ->
        cond do
          File.exists?(Path.join(path, "bun.lockb")) -> "bun"
          File.exists?(Path.join(path, "pnpm-lock.yaml")) -> "pnpm"
          File.exists?(Path.join(path, "yarn.lock")) -> "yarn"
          true -> "npm"
        end
      File.exists?(Path.join(path, "Cargo.toml")) -> "cargo"
      File.exists?(Path.join(path, "go.mod")) -> "go"
      File.exists?(Path.join(path, "Makefile")) -> "make"
      true -> "unknown"
    end
  end

  defp detect_test_dir(path) do
    cond do
      File.dir?(Path.join(path, "test")) -> "test"
      File.dir?(Path.join(path, "tests")) -> "tests"
      File.dir?(Path.join(path, "spec")) -> "spec"
      File.dir?(Path.join(path, "__tests__")) -> "__tests__"
      true -> nil
    end
  end

  defp detect_git_info(path) do
    if File.dir?(Path.join(path, ".git")) do
      branch =
        case System.cmd("git", ["branch", "--show-current"], cd: path, stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "unknown"
        end

      %{initialized: true, branch: branch}
    else
      %{initialized: false}
    end
  rescue
    _ -> %{initialized: false}
  end

  # -- codebase_map ------------------------------------------------------------

  defp codebase_map_tool do
    ReqLLM.Tool.new!(
      name: "codebase_map",
      description: "Generate a directory tree of the project, excluding build artifacts and dependencies.",
      parameter_schema: [
        path: [type: :string, doc: "Root path (default: current comb)"],
        depth: [type: :integer, doc: "Max depth (default: 3)"]
      ],
      callback: &codebase_map/1
    )
  end

  defp codebase_map(args) do
    path = resolve_project_path(args["path"] || args[:path])
    depth = args["depth"] || args[:depth] || 3

    tree = build_tree(path, depth, 0)
    {:ok, tree}
  rescue
    e -> {:ok, "Error: #{Exception.message(e)}"}
  end

  defp build_tree(path, max_depth, current_depth) do
    indent = String.duplicate("  ", current_depth)
    name = Path.basename(path)

    if File.dir?(path) do
      if current_depth >= max_depth do
        "#{indent}#{name}/"
      else
        children =
          case File.ls(path) do
            {:ok, entries} ->
              entries
              |> Enum.sort()
              |> Enum.reject(&(&1 in @skip_dirs or String.starts_with?(&1, ".")))
              |> Enum.map(&build_tree(Path.join(path, &1), max_depth, current_depth + 1))
              |> Enum.join("\n")

            {:error, _} ->
              ""
          end

        "#{indent}#{name}/\n#{children}"
      end
    else
      "#{indent}#{name}"
    end
  end

  # -- dependency_info ---------------------------------------------------------

  defp dependency_info_tool do
    ReqLLM.Tool.new!(
      name: "dependency_info",
      description: "Parse project dependency files (mix.lock, package.json, Cargo.toml) and list dependencies.",
      parameter_schema: [
        path: [type: :string, doc: "Project root path (default: current comb)"]
      ],
      callback: &dependency_info/1
    )
  end

  defp dependency_info(args) do
    path = resolve_project_path(args["path"] || args[:path])

    deps =
      cond do
        File.exists?(Path.join(path, "mix.lock")) ->
          parse_mix_lock(Path.join(path, "mix.lock"))

        File.exists?(Path.join(path, "package.json")) ->
          parse_package_json(Path.join(path, "package.json"))

        File.exists?(Path.join(path, "Cargo.toml")) ->
          parse_cargo_toml(Path.join(path, "Cargo.toml"))

        true ->
          %{error: "No recognized dependency file found"}
      end

    {:ok, format_map(deps)}
  rescue
    e -> {:ok, "Error: #{Exception.message(e)}"}
  end

  defp parse_mix_lock(path) do
    case File.read(path) do
      {:ok, content} ->
        deps =
          content
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, ":"))
          |> Enum.map(fn line ->
            case Regex.run(~r/"(\w+)":\s*\{/, line) do
              [_, name] -> name
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        %{type: "mix", count: length(deps), dependencies: deps}

      {:error, _} ->
        %{error: "Could not read mix.lock"}
    end
  end

  defp parse_package_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, json} ->
            deps = Map.keys(json["dependencies"] || %{})
            dev_deps = Map.keys(json["devDependencies"] || %{})

            %{
              type: "npm",
              dependencies: deps,
              dev_dependencies: dev_deps,
              count: length(deps) + length(dev_deps)
            }

          {:error, _} ->
            %{error: "Invalid package.json"}
        end

      {:error, _} ->
        %{error: "Could not read package.json"}
    end
  end

  defp parse_cargo_toml(path) do
    case File.read(path) do
      {:ok, content} ->
        deps =
          content
          |> String.split("\n")
          |> Enum.reduce({false, []}, fn line, {in_deps, acc} ->
            cond do
              String.starts_with?(line, "[dependencies]") -> {true, acc}
              String.starts_with?(line, "[") -> {false, acc}
              in_deps and String.contains?(line, "=") ->
                [name | _] = String.split(line, "=", parts: 2)
                {true, [String.trim(name) | acc]}
              true -> {in_deps, acc}
            end
          end)
          |> elem(1)
          |> Enum.reverse()

        %{type: "cargo", count: length(deps), dependencies: deps}

      {:error, _} ->
        %{error: "Could not read Cargo.toml"}
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp resolve_project_path(nil) do
    case Hive.Comb.current() do
      {:ok, comb} -> comb.path
      _ -> File.cwd!()
    end
  rescue
    _ -> File.cwd!()
  end

  defp resolve_project_path(path), do: Path.expand(path)

  defp format_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end
end
