defmodule Hive.OnboardingTest do
  use ExUnit.Case, async: false
  alias Hive.{Onboarding, Store}

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("hive_onboarding_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(tmp_dir)
    
    # Create a test Elixir project
    project_dir = Path.join(tmp_dir, "test_project")
    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "mix.exs"), "defmodule TestProject.MixProject do\nend")
    File.mkdir_p!(Path.join(project_dir, "lib"))
    File.mkdir_p!(Path.join(project_dir, "test"))
    
    # Initialize git repo
    System.cmd("git", ["init"], cd: project_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: project_dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: project_dir)
    
    # Start Store
    store_dir = Path.join(tmp_dir, "store")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, project_dir: project_dir}
  end

  test "preview shows project detection results", %{project_dir: project_dir} do
    {:ok, info} = Onboarding.preview(project_dir)
    
    assert info.project_info.language == :elixir
    assert info.project_info.build_tool == :mix
    assert info.project_info.test_framework == :exunit
    assert info.suggestions.validation_command == "mix test"
    assert info.suggestions.name == "test_project"
  end

  test "quick_onboard creates comb without research", %{project_dir: project_dir} do
    {:ok, result} = Onboarding.quick_onboard(project_dir, name: "test_comb")
    
    assert result.comb.name == "test_comb"
    assert result.comb.path == project_dir
    assert result.project_info.language == :elixir
    assert result.comb.validation_command == "mix test"
  end

  test "onboard creates comb with auto-detected settings", %{project_dir: project_dir} do
    {:ok, result} = Onboarding.onboard(project_dir, name: "auto_comb", skip_research: true)
    
    assert result.comb.name == "auto_comb"
    assert result.comb.validation_command == "mix test"
    assert result.project_info.language == :elixir
    assert result.project_info.build_tool == :mix
    assert result.project_info.project_type == :library
  end

  test "onboard with custom validation command", %{project_dir: project_dir} do
    {:ok, result} = Onboarding.onboard(project_dir, 
      name: "custom_comb",
      validation_command: "mix test --only unit",
      skip_research: true
    )
    
    assert result.comb.validation_command == "mix test --only unit"
  end

  test "onboard fails for non-existent path" do
    {:error, reason} = Onboarding.onboard("/nonexistent/path")
    assert reason =~ "does not exist"
  end

  test "onboard fails for non-git directory" do
    tmp_dir = System.tmp_dir!() |> Path.join("not_git_#{:rand.uniform(1000000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    
    {:error, reason} = Onboarding.onboard(tmp_dir)
    assert reason =~ "not a git repository"
  end

  test "suggests merge strategy based on project type", %{project_dir: project_dir} do
    # Library project should suggest pr_branch
    {:ok, result} = Onboarding.onboard(project_dir, skip_research: true)
    assert result.comb.merge_strategy == :pr_branch
  end
end
