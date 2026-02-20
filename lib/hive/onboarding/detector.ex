defmodule Hive.Onboarding.Detector do
  @moduledoc """
  Auto-detects project type, language, framework, and tooling from a codebase.
  """

  @doc """
  Detects project characteristics from a directory path.
  
  Returns a map with:
  - :language - Primary language
  - :framework - Framework (if detected)
  - :build_tool - Build/package manager
  - :test_framework - Test framework
  - :validation_command - Suggested validation command
  - :project_type - Type of project (web, library, cli, etc.)
  """
  def detect(path) do
    files = list_files(path)
    
    %{
      language: detect_language(files, path),
      framework: detect_framework(files, path),
      build_tool: detect_build_tool(files, path),
      test_framework: detect_test_framework(files, path),
      validation_command: suggest_validation_command(files, path),
      project_type: detect_project_type(files, path)
    }
  end

  defp list_files(path) do
    case File.ls(path) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  defp detect_language(files, path) do
    cond do
      has_file?(files, "mix.exs") -> :elixir
      has_file?(files, "package.json") -> :javascript
      has_file?(files, "Cargo.toml") -> :rust
      has_file?(files, "go.mod") -> :go
      has_file?(files, "requirements.txt") or has_file?(files, "pyproject.toml") -> :python
      has_file?(files, "Gemfile") -> :ruby
      has_file?(files, "pom.xml") or has_file?(files, "build.gradle") -> :java
      has_file?(files, "Package.swift") -> :swift
      has_file?(files, "Makefile") and has_dir?(files, "src", path) -> :c
      true -> :unknown
    end
  end

  defp detect_framework(files, path) do
    cond do
      has_file?(files, "mix.exs") and has_phoenix?(files, path) -> :phoenix
      has_file?(files, "package.json") and has_react?(files, path) -> :react
      has_file?(files, "package.json") and has_next?(files, path) -> :nextjs
      has_file?(files, "package.json") and has_vue?(files, path) -> :vue
      has_file?(files, "Gemfile") and has_rails?(files, path) -> :rails
      has_file?(files, "requirements.txt") and has_django?(files, path) -> :django
      has_file?(files, "requirements.txt") and has_flask?(files, path) -> :flask
      has_file?(files, "go.mod") and has_gin?(files, path) -> :gin
      true -> nil
    end
  end

  defp detect_build_tool(files, _path) do
    cond do
      has_file?(files, "mix.exs") -> :mix
      has_file?(files, "package.json") and has_file?(files, "package-lock.json") -> :npm
      has_file?(files, "package.json") and has_file?(files, "yarn.lock") -> :yarn
      has_file?(files, "package.json") and has_file?(files, "pnpm-lock.yaml") -> :pnpm
      has_file?(files, "Cargo.toml") -> :cargo
      has_file?(files, "go.mod") -> :go
      has_file?(files, "requirements.txt") -> :pip
      has_file?(files, "pyproject.toml") -> :poetry
      has_file?(files, "Gemfile") -> :bundler
      has_file?(files, "pom.xml") -> :maven
      has_file?(files, "build.gradle") -> :gradle
      has_file?(files, "Makefile") -> :make
      true -> nil
    end
  end

  defp detect_test_framework(files, path) do
    cond do
      has_file?(files, "mix.exs") -> :exunit
      has_jest?(files, path) -> :jest
      has_vitest?(files, path) -> :vitest
      has_pytest?(files, path) -> :pytest
      has_file?(files, "Gemfile") and has_rspec?(files, path) -> :rspec
      has_file?(files, "Cargo.toml") -> :cargo_test
      has_file?(files, "go.mod") -> :go_test
      true -> nil
    end
  end

  defp suggest_validation_command(files, path) do
    cond do
      has_file?(files, "mix.exs") -> "mix test"
      has_jest?(files, path) -> "npm test"
      has_vitest?(files, path) -> "npm test"
      has_file?(files, "Cargo.toml") -> "cargo test"
      has_file?(files, "go.mod") -> "go test ./..."
      has_pytest?(files, path) -> "pytest"
      has_rspec?(files, path) -> "bundle exec rspec"
      has_file?(files, "pom.xml") -> "mvn test"
      has_file?(files, "build.gradle") -> "gradle test"
      has_file?(files, "Makefile") -> "make test"
      true -> nil
    end
  end

  defp detect_project_type(files, path) do
    cond do
      has_phoenix?(files, path) or has_rails?(files, path) or has_django?(files, path) -> :web_app
      has_react?(files, path) or has_vue?(files, path) or has_next?(files, path) -> :frontend
      has_file?(files, "mix.exs") and has_dir?(files, "lib", path) -> :library
      has_file?(files, "package.json") and has_cli_indicators?(files, path) -> :cli
      has_file?(files, "Cargo.toml") and has_bin?(files, path) -> :cli
      true -> :application
    end
  end

  # Helper functions for framework detection
  defp has_phoenix?(files, path) do
    has_dir?(files, "lib", path) and has_dir?(files, "assets", path)
  end

  defp has_react?(files, path) do
    has_file?(files, "package.json") and read_file_contains?(path, "package.json", "\"react\"")
  end

  defp has_next?(files, path) do
    has_file?(files, "package.json") and read_file_contains?(path, "package.json", "\"next\"")
  end

  defp has_vue?(files, path) do
    has_file?(files, "package.json") and read_file_contains?(path, "package.json", "\"vue\"")
  end

  defp has_rails?(files, path) do
    has_file?(files, "Gemfile") and has_file?(files, "config.ru")
  end

  defp has_django?(files, path) do
    has_file?(files, "manage.py")
  end

  defp has_flask?(files, path) do
    has_file?(files, "requirements.txt") and read_file_contains?(path, "requirements.txt", "Flask")
  end

  defp has_gin?(files, path) do
    has_file?(files, "go.mod") and read_file_contains?(path, "go.mod", "gin-gonic/gin")
  end

  defp has_jest?(files, path) do
    has_file?(files, "package.json") and read_file_contains?(path, "package.json", "\"jest\"")
  end

  defp has_vitest?(files, path) do
    has_file?(files, "package.json") and read_file_contains?(path, "package.json", "\"vitest\"")
  end

  defp has_pytest?(files, path) do
    (has_file?(files, "requirements.txt") and read_file_contains?(path, "requirements.txt", "pytest")) or
    (has_file?(files, "pyproject.toml") and read_file_contains?(path, "pyproject.toml", "pytest"))
  end

  defp has_rspec?(files, path) do
    has_dir?(files, "spec", path)
  end

  defp has_cli_indicators?(files, path) do
    has_file?(files, "bin") or has_dir?(files, "bin", path)
  end

  defp has_bin?(files, path) do
    has_file?(files, "Cargo.toml") and read_file_contains?(path, "Cargo.toml", "[[bin]]")
  end

  defp has_file?(files, name), do: Enum.member?(files, name)
  
  defp has_dir?(files, name, path) do
    Enum.member?(files, name) and File.dir?(Path.join(path, name))
  end

  defp read_file_contains?(path, file, pattern) do
    case File.read(Path.join(path, file)) do
      {:ok, content} -> String.contains?(content, pattern)
      _ -> false
    end
  end
end
