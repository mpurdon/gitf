defmodule GiTF.Onboarding.DetectorTest do
  use ExUnit.Case, async: true
  alias GiTF.Onboarding.Detector

  setup do
    # Create a temporary directory for test projects
    tmp_dir = System.tmp_dir!() |> Path.join("gitf_detector_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "detects Elixir project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MyApp.MixProject do\nend")
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    result = Detector.detect(tmp_dir)

    assert result.language == :elixir
    assert result.build_tool == :mix
    assert result.test_framework == :exunit
    assert result.validation_command == "mix test"
  end

  test "detects Phoenix project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MyApp.MixProject do\nend")
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "assets"))

    result = Detector.detect(tmp_dir)

    assert result.language == :elixir
    assert result.framework == :phoenix
    assert result.project_type == :web_app
  end

  test "detects JavaScript/Node project with npm", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "package.json"), ~s({"name": "test"}))
    File.write!(Path.join(tmp_dir, "package-lock.json"), "{}")

    result = Detector.detect(tmp_dir)

    assert result.language == :javascript
    assert result.build_tool == :npm
  end

  test "detects React project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "package.json"), ~s({"dependencies": {"react": "^18.0.0"}}))

    result = Detector.detect(tmp_dir)

    assert result.language == :javascript
    assert result.framework == :react
    assert result.project_type == :frontend
  end

  test "detects Rust project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]\nname = \"test\"")

    result = Detector.detect(tmp_dir)

    assert result.language == :rust
    assert result.build_tool == :cargo
    assert result.test_framework == :cargo_test
    assert result.validation_command == "cargo test"
  end

  test "detects Go project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "go.mod"), "module test")

    result = Detector.detect(tmp_dir)

    assert result.language == :go
    assert result.build_tool == :go
    assert result.test_framework == :go_test
    assert result.validation_command == "go test ./..."
  end

  test "detects Python project with pip", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "requirements.txt"), "flask==2.0.0")

    result = Detector.detect(tmp_dir)

    assert result.language == :python
    assert result.build_tool == :pip
  end

  test "detects Python project with pytest", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "requirements.txt"), "pytest==7.0.0")

    result = Detector.detect(tmp_dir)

    assert result.language == :python
    assert result.test_framework == :pytest
    assert result.validation_command == "pytest"
  end

  test "detects Ruby/Rails project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Gemfile"), "source 'https://rubygems.org'")
    File.write!(Path.join(tmp_dir, "config.ru"), "run Rails.application")

    result = Detector.detect(tmp_dir)

    assert result.language == :ruby
    assert result.framework == :rails
    assert result.project_type == :web_app
  end

  test "returns unknown for unrecognized project", %{tmp_dir: tmp_dir} do
    result = Detector.detect(tmp_dir)

    assert result.language == :unknown
    assert result.build_tool == nil
    assert result.validation_command == nil
  end

  # cora looked like a plain React app because nothing knew about Tauri, so it
  # drew a React-sized validation budget for an npm install plus a Rust build.
  describe "Tauri detection" do
    test "detects a src-tauri directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "package.json"), ~s({"name": "cora"}))
      File.mkdir_p!(Path.join(tmp_dir, "src-tauri"))

      assert Detector.detect(tmp_dir).framework == :tauri
    end

    test "detects @tauri-apps/ in package.json and wins over :react", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, "package.json"),
        ~s({"dependencies": {"react": "^18.0.0", "@tauri-apps/api": "^2.0.0"}})
      )

      result = Detector.detect(tmp_dir)

      assert result.language == :javascript
      assert result.framework == :tauri
    end

    test "a plain React app is still :react", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "package.json"), ~s({"dependencies": {"react": "^18.0.0"}}))

      assert Detector.detect(tmp_dir).framework == :react
    end
  end

  describe "derive_validation_timeout_ms/2" do
    test "buckets by project type" do
      assert derive(%{framework: :tauri}) == 1_800_000
      assert derive(%{language: :rust, build_tool: :cargo}) == 1_200_000
      assert derive(%{language: :java, build_tool: :maven}) == 1_200_000
      assert derive(%{language: :java, build_tool: :gradle}) == 1_200_000
      assert derive(%{language: :elixir, build_tool: :mix}) == 900_000
      assert derive(%{language: :swift}) == 900_000
      assert derive(%{language: :javascript}) == 600_000
      assert derive(%{language: :python}) == 600_000
      assert derive(%{language: :ruby}) == 600_000
      assert derive(%{language: :c, build_tool: :make}) == 600_000
      assert derive(%{language: :go}) == 300_000
      assert derive(%{language: :unknown}) == 600_000
    end

    test "a sector with no validation command keeps the 2-minute default" do
      assert Detector.derive_validation_timeout_ms(%{language: :rust, validation_command: nil}) ==
               120_000

      assert Detector.derive_validation_timeout_ms(%{language: :rust}, "   ") == 120_000
    end

    test "doubles the budget for commands that announce a cold fetch or build" do
      assert derive(%{language: :javascript}, "npm ci && npm test") == 1_200_000
      assert derive(%{language: :javascript}, "npm install && npm test") == 1_200_000
      assert derive(%{language: :elixir}, "mix deps.get && mix test") == 1_800_000
      assert derive(%{language: :go}, "go test ./...") == 300_000
      assert derive(%{language: :go}, "bash /var/lib/gitf/probes/smoke.sh") == 600_000
    end

    test "caps at 30 minutes" do
      assert derive(%{framework: :tauri}, "npm ci && cargo build --release") == 1_800_000

      assert derive(%{language: :rust, build_tool: :cargo}, "cargo build && cargo test") ==
               1_800_000
    end

    test "the explicit command overrules the detected one" do
      info = %{language: :go, validation_command: "go test ./..."}

      assert Detector.derive_validation_timeout_ms(info) == 300_000
      assert Detector.derive_validation_timeout_ms(info, "npm ci && npm test") == 600_000
    end

    # The command that killed the mission: every op reported :timeout at 120s
    # and manufactured six fix ghosts that then merge-conflicted.
    test "cora's real validation command earns at least 15 minutes" do
      cora =
        "npm ci && test -f node_modules/typescript/lib/lib.es5.d.ts || " <>
          "(rm -rf node_modules && npm cache verify && npm ci) ; npm run typecheck && " <>
          "bash /var/lib/gitf/probes/cora-smoke.sh"

      # Detected against the live checkout.
      assert derive(%{language: :javascript, framework: :tauri, build_tool: :npm}, cora) ==
               1_800_000

      # And with the checkout gone, from the command shape alone.
      assert derive(%{}, cora) >= 900_000
    end

    test "detect/1 includes the derived budget", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule MyApp.MixProject do\nend")

      assert Detector.detect(tmp_dir).validation_timeout_ms == 900_000
    end
  end

  defp derive(info, command \\ "some validation command"),
    do: Detector.derive_validation_timeout_ms(info, command)
end
