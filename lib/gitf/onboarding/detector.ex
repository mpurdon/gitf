defmodule GiTF.Onboarding.Detector do
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
  - :validation_timeout_ms - Derived validation deadline
  - :project_type - Type of project (web, library, cli, etc.)
  """
  def detect(path) do
    files = list_files(path)

    info = %{
      language: detect_language(files, path),
      framework: detect_framework(files, path),
      build_tool: detect_build_tool(files, path),
      test_framework: detect_test_framework(files, path),
      validation_command: suggest_validation_command(files, path),
      project_type: detect_project_type(files, path)
    }

    # Derived from the map just built — the timeout helper used to re-run
    # every detector (re-reading package.json and mix.exs off disk) to
    # rebuild the same map it was standing next to.
    Map.put(info, :validation_timeout_ms, derive_validation_timeout_ms(info))
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
      # Ahead of :react/:nextjs/:vue on purpose. A Tauri app is a web frontend
      # *plus* a Rust host binary, so it looked like a plain React app and drew
      # a React-sized validation budget it could never meet.
      has_tauri?(files, path) -> :tauri
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

  # The ceiling lives with the read side — GiTF.Validator — so the write
  # surfaces and this derivation cannot drift apart.

  # What every sector silently got, because nothing ever wrote the field.
  @no_command_timeout_ms 120_000

  @cold_build_markers ["npm ci", "npm install", "cargo build", "mix deps.get", "probes/"]

  @doc """
  Derives a validation deadline (ms) from detected project characteristics and,
  optionally, the validation command actually stored on the sector.

  Validation runs in a *fresh* git worktree inside a sandbox, so the dependency
  fetch and the cold compile happen on essentially every run — the install/build
  term dominates the wall clock, not the test term. That is why the buckets look
  so generous next to a warm local `mix test`.

  Derived rather than typed on purpose: the factory runs many heterogeneous
  sectors unattended and nobody is around to notice a mis-set number. The
  `sector set --validation-timeout-ms` override is the escape hatch, not the
  mechanism.

  `command` wins over `project_info.validation_command` when given, because an
  operator's compound command is what actually runs. cora's is
  `npm ci && … npm run typecheck && bash …/probes/cora-smoke.sh` — a full npm
  install, a typecheck, and a Tauri build-and-launch probe. At the 120s default
  every op reported `:timeout`, which manufactured six spurious fix ghosts that
  then merge-conflicted and failed the mission.
  """
  @spec derive_validation_timeout_ms(map(), String.t() | nil) :: pos_integer()
  def derive_validation_timeout_ms(project_info, command \\ nil) do
    command = command || Map.get(project_info, :validation_command)

    if is_nil(command) or String.trim(command) == "" do
      @no_command_timeout_ms
    else
      # Operators write compound commands the detector would never suggest, so
      # the shape of the command overrules the project type when it announces a
      # cold dependency fetch or a native build.
      multiplier = if cold_build_command?(command), do: 2, else: 1

      min(
        base_validation_timeout_ms(project_info) * multiplier,
        GiTF.Validator.max_validation_timeout_ms()
      )
    end
  end

  defp base_validation_timeout_ms(info) do
    language = Map.get(info, :language)
    framework = Map.get(info, :framework)
    build_tool = Map.get(info, :build_tool)

    cond do
      # Tauri: npm install, a Rust release build, and then launching the app.
      framework == :tauri -> 1_800_000
      language == :rust or build_tool == :cargo -> 1_200_000
      build_tool in [:maven, :gradle] -> 1_200_000
      language == :elixir or build_tool == :mix -> 900_000
      language == :swift -> 900_000
      language == :go -> 300_000
      true -> 600_000
    end
  end

  defp cold_build_command?(command) do
    Enum.any?(@cold_build_markers, &String.contains?(command, &1))
  end

  defp has_tauri?(files, path) do
    has_dir?(files, "src-tauri", path) or
      (has_file?(files, "package.json") and
         read_file_contains?(path, "package.json", "@tauri-apps/"))
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

  defp has_rails?(files, _path) do
    has_file?(files, "Gemfile") and has_file?(files, "config.ru")
  end

  defp has_django?(files, _path) do
    has_file?(files, "manage.py")
  end

  defp has_flask?(files, path) do
    has_file?(files, "requirements.txt") and
      read_file_contains?(path, "requirements.txt", "Flask")
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
    (has_file?(files, "requirements.txt") and
       read_file_contains?(path, "requirements.txt", "pytest")) or
      (has_file?(files, "pyproject.toml") and
         read_file_contains?(path, "pyproject.toml", "pytest"))
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
