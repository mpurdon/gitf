defmodule Hive.Queen.ResearchTest do
  use ExUnit.Case, async: false

  alias Hive.Queen.Research
  alias Hive.Store

  setup do
    # Start store for testing
    {:ok, _} = Store.start_link(data_dir: System.tmp_dir!() <> "/test_research_#{:rand.uniform(10000)}")
    
    # Create test directory structure
    test_path = System.tmp_dir!() <> "/test_codebase_#{:rand.uniform(10000)}"
    File.mkdir_p!(test_path)
    File.mkdir_p!(Path.join(test_path, "lib"))
    File.mkdir_p!(Path.join(test_path, "test"))
    
    # Create test files
    File.write!(Path.join(test_path, "lib/app.ex"), "defmodule App do\nend")
    File.write!(Path.join(test_path, "lib/utils.ex"), "defmodule Utils do\nend")
    File.write!(Path.join(test_path, "test/app_test.exs"), "defmodule AppTest do\nend")
    File.write!(Path.join(test_path, "README.md"), "# Test Project")
    
    # Initialize git repo
    System.cmd("git", ["init"], cd: test_path)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: test_path)
    System.cmd("git", ["config", "user.name", "Test User"], cd: test_path)
    System.cmd("git", ["add", "."], cd: test_path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: test_path)
    
    # Create test comb
    {:ok, comb} = Store.insert(:combs, %{
      name: "test-comb",
      path: test_path
    })
    
    {:ok, comb: comb, test_path: test_path}
  end

  test "analyze_structure returns correct file analysis", %{test_path: test_path} do
    {:ok, structure} = Research.analyze_structure(test_path)
    
    assert structure.total_files == 4
    assert structure.file_types[".ex"] == 2
    assert structure.file_types[".exs"] == 1
    assert structure.file_types[".md"] == 1
    assert structure.main_language == "elixir"
    assert "lib" in structure.directories
    assert "test" in structure.directories
  end

  test "perform_fresh_research stores cache", %{comb: comb} do
    {:ok, cache} = Research.perform_fresh_research(comb.id)
    
    assert cache.research.analysis_type == "basic_structure"
    assert cache.research.structure.total_files == 4
    assert cache.research.structure.main_language == "elixir"
    assert is_struct(cache.research.analyzed_at, DateTime)
  end

  test "research_comb uses cache when valid", %{comb: comb} do
    # First call should create cache
    {:ok, result1} = Research.research_comb(comb.id)
    
    # Second call should use cache (same analyzed_at timestamp)
    {:ok, result2} = Research.research_comb(comb.id)
    
    assert result1.research.analyzed_at == result2.research.analyzed_at
  end

  test "research_comb refreshes cache when invalid", %{comb: comb} do
    # First call creates cache
    {:ok, result1} = Research.research_comb(comb.id)
    
    # Make git change to invalidate cache
    File.write!(Path.join(comb.path, "new_file.ex"), "defmodule New do\nend")
    System.cmd("git", ["add", "."], cd: comb.path)
    System.cmd("git", ["commit", "-m", "Add new file"], cd: comb.path)
    
    # Second call should refresh cache
    {:ok, result2} = Research.research_comb(comb.id)
    
    assert result1.research.analyzed_at != result2.research.analyzed_at
    assert result2.research.structure.total_files == 5
  end

  test "detect_main_language handles various file types" do
    files = ["app.py", "utils.py", "test.js", "config.rb"]
    
    # Python should win (2 files vs 1 each)
    extensions = Research.group_by_extension(files)
    language = Research.detect_main_language(files)
    
    assert extensions[".py"] == 2
    assert language == "python"
  end

  test "analyze_structure handles empty directory", %{test_path: test_path} do
    empty_path = Path.join(test_path, "empty")
    File.mkdir_p!(empty_path)
    
    {:ok, structure} = Research.analyze_structure(empty_path)
    
    assert structure.total_files == 0
    assert structure.file_types == %{}
    assert structure.directories == []
    assert structure.main_language == "unknown"
  end
end