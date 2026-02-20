defmodule Hive.Research.CacheTest do
  use ExUnit.Case, async: false

  alias Hive.Research.Cache
  alias Hive.Store

  setup do
    # Start store for testing
    {:ok, _} = Store.start_link(data_dir: System.tmp_dir!() <> "/test_cache_#{:rand.uniform(10000)}")
    
    # Create test comb
    {:ok, comb} = Store.insert(:combs, %{
      name: "test-comb",
      path: System.tmp_dir!() <> "/test_repo_#{:rand.uniform(10000)}"
    })
    
    # Create git repo
    File.mkdir_p!(comb.path)
    System.cmd("git", ["init"], cd: comb.path)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: comb.path)
    System.cmd("git", ["config", "user.name", "Test User"], cd: comb.path)
    File.write!(Path.join(comb.path, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: comb.path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: comb.path)
    
    {:ok, comb: comb}
  end

  test "get_research returns not_found for non-existent cache", %{comb: comb} do
    assert {:error, :not_found} = Cache.get_research(comb.id)
  end

  test "store_research and get_research work correctly", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    
    {:ok, cache} = Cache.store_research(comb.id, research)
    
    assert cache.comb_id == comb.id
    assert cache.research == research
    assert is_binary(cache.git_hash)
    
    {:ok, retrieved} = Cache.get_research(comb.id)
    assert retrieved.research == research
  end

  test "is_valid? returns true for fresh cache", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(comb.id, research)
    
    assert Cache.is_valid?(comb.id) == true
  end

  test "is_valid? returns false after git changes", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(comb.id, research)
    
    # Make a git change
    File.write!(Path.join(comb.path, "new_file.txt"), "content")
    System.cmd("git", ["add", "."], cd: comb.path)
    System.cmd("git", ["commit", "-m", "Add new file"], cd: comb.path)
    
    assert Cache.is_valid?(comb.id) == false
  end

  test "update_research merges with existing cache", %{comb: comb} do
    initial = %{structure: %{total_files: 1}}
    Cache.store_research(comb.id, initial)
    
    update = %{patterns: %{mvc: true}}
    {:ok, updated} = Cache.update_research(comb.id, update)
    
    expected = Map.merge(initial, update)
    assert updated.research == expected
  end

  test "invalidate removes cache and file index", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    file_index = [%{path: "test.ex", research: %{type: "module"}}]
    
    Cache.store_research(comb.id, research, file_index)
    
    # Verify cache exists
    assert {:ok, _} = Cache.get_research(comb.id)
    
    # Invalidate
    Cache.invalidate(comb.id)
    
    # Verify cache is gone
    assert {:error, :not_found} = Cache.get_research(comb.id)
  end

  test "get_file_research works with file index", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    file_research = %{type: "module", functions: 3}
    file_index = [%{path: "test.ex", research: file_research}]
    
    Cache.store_research(comb.id, research, file_index)
    
    {:ok, file_cache} = Cache.get_file_research(comb.id, "test.ex")
    assert file_cache.research == file_research
    assert file_cache.file_path == "test.ex"
  end

  test "get_file_research returns not_found for non-existent file", %{comb: comb} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(comb.id, research)
    
    assert {:error, :not_found} = Cache.get_file_research(comb.id, "nonexistent.ex")
  end
end