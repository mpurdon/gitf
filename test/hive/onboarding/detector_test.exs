defmodule Hive.Onboarding.DetectorTest do
  use ExUnit.Case, async: true
  alias Hive.Onboarding.Detector

  setup do
    # Create a temporary directory for test projects
    tmp_dir = System.tmp_dir!() |> Path.join("hive_detector_test_#{:rand.uniform(1000000)}")
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
end
