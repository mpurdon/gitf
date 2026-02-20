defmodule Hive.Onboarding.Mapper do
  @moduledoc """
  Generates a structural map of a codebase for quick understanding.
  """

  @doc """
  Creates a codebase map with key information.
  
  Returns a map with:
  - :structure - Directory tree
  - :entry_points - Main files/modules
  - :dependencies - External dependencies
  - :file_count - Total files by type
  - :summary - Human-readable summary
  """
  def map(path, project_info) do
    %{
      structure: analyze_structure(path, project_info.language),
      entry_points: find_entry_points(path, project_info),
      dependencies: extract_dependencies(path, project_info),
      file_count: count_files(path, project_info.language),
      summary: generate_summary(path, project_info)
    }
  end

  defp analyze_structure(path, language) do
    key_dirs = key_directories(language)
    
    key_dirs
    |> Enum.filter(fn dir -> File.dir?(Path.join(path, dir)) end)
    |> Enum.map(fn dir -> 
      full_path = Path.join(path, dir)
      {dir, count_files_in_dir(full_path)}
    end)
    |> Map.new()
  end

  defp key_directories(:elixir), do: ["lib", "test", "priv", "config"]
  defp key_directories(:javascript), do: ["src", "test", "tests", "public", "dist"]
  defp key_directories(:rust), do: ["src", "tests", "benches", "examples"]
  defp key_directories(:go), do: ["cmd", "pkg", "internal", "api"]
  defp key_directories(:python), do: ["src", "tests", "docs"]
  defp key_directories(:ruby), do: ["lib", "app", "spec", "test", "config"]
  defp key_directories(_), do: ["src", "test", "tests"]

  defp find_entry_points(path, %{language: :elixir}) do
    find_files(path, "lib", "*.ex")
    |> Enum.filter(&is_application_file?/1)
    |> Enum.take(5)
  end

  defp find_entry_points(path, %{language: :javascript, project_type: :frontend}) do
    ["src/index.js", "src/index.ts", "src/main.js", "src/main.ts", "src/App.jsx", "src/App.tsx"]
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp find_entry_points(path, %{language: :javascript}) do
    ["index.js", "server.js", "app.js", "src/index.js", "src/server.js"]
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp find_entry_points(path, %{language: :rust}) do
    ["src/main.rs", "src/lib.rs"]
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp find_entry_points(path, %{language: :go}) do
    find_files(path, "cmd", "main.go") ++ 
    find_files(path, ".", "main.go")
    |> Enum.take(5)
  end

  defp find_entry_points(path, %{language: :python}) do
    ["__main__.py", "main.py", "app.py", "manage.py"]
    |> Enum.map(&Path.join(path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  defp find_entry_points(_path, _), do: []

  defp extract_dependencies(path, %{build_tool: :mix}) do
    case File.read(Path.join(path, "mix.exs")) do
      {:ok, content} -> parse_mix_deps(content)
      _ -> []
    end
  end

  defp extract_dependencies(path, %{build_tool: tool}) when tool in [:npm, :yarn, :pnpm] do
    case File.read(Path.join(path, "package.json")) do
      {:ok, content} -> parse_package_json_deps(content)
      _ -> []
    end
  end

  defp extract_dependencies(path, %{build_tool: :cargo}) do
    case File.read(Path.join(path, "Cargo.toml")) do
      {:ok, content} -> parse_cargo_deps(content)
      _ -> []
    end
  end

  defp extract_dependencies(path, %{build_tool: :go}) do
    case File.read(Path.join(path, "go.mod")) do
      {:ok, content} -> parse_go_deps(content)
      _ -> []
    end
  end

  defp extract_dependencies(_path, _), do: []

  defp parse_mix_deps(content) do
    Regex.scan(~r/{:(\w+),/, content)
    |> Enum.map(fn [_, dep] -> dep end)
    |> Enum.take(10)
  end

  defp parse_package_json_deps(content) do
    case Jason.decode(content) do
      {:ok, %{"dependencies" => deps}} -> 
        deps |> Map.keys() |> Enum.take(10)
      _ -> []
    end
  end

  defp parse_cargo_deps(content) do
    Regex.scan(~r/^(\w+)\s*=/, content, multiline: true)
    |> Enum.map(fn [_, dep] -> dep end)
    |> Enum.reject(&(&1 in ["package", "dependencies", "dev"]))
    |> Enum.take(10)
  end

  defp parse_go_deps(content) do
    Regex.scan(~r/require\s+([^\s]+)/, content)
    |> Enum.map(fn [_, dep] -> dep end)
    |> Enum.take(10)
  end

  defp count_files(path, language) do
    extensions = file_extensions(language)
    
    extensions
    |> Enum.map(fn ext ->
      count = count_files_with_ext(path, ext)
      {ext, count}
    end)
    |> Map.new()
  end

  defp file_extensions(:elixir), do: [".ex", ".exs"]
  defp file_extensions(:javascript), do: [".js", ".jsx", ".ts", ".tsx"]
  defp file_extensions(:rust), do: [".rs"]
  defp file_extensions(:go), do: [".go"]
  defp file_extensions(:python), do: [".py"]
  defp file_extensions(:ruby), do: [".rb"]
  defp file_extensions(_), do: []

  defp count_files_with_ext(path, ext) do
    Path.wildcard(Path.join([path, "**", "*#{ext}"]))
    |> length()
  end

  defp count_files_in_dir(path) do
    case File.ls(path) do
      {:ok, files} -> length(files)
      _ -> 0
    end
  end

  defp find_files(path, dir, pattern) do
    Path.wildcard(Path.join([path, dir, "**", pattern]))
  end

  defp is_application_file?(file) do
    content = File.read!(file)
    String.contains?(content, "use Application") or
    String.contains?(content, "defmodule") and String.contains?(content, ".Application")
  end

  defp generate_summary(path, project_info) do
    %{
      language: project_info.language,
      framework: project_info.framework,
      build_tool: project_info.build_tool,
      test_framework: project_info.test_framework,
      project_type: project_info.project_type,
      path: path
    }
  end
end
