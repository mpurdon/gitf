defmodule GiTF.Research.CacheTest do
  use ExUnit.Case, async: false

  alias GiTF.Research.Cache
  alias GiTF.Archive

  setup do
    # Start store for testing
    GiTF.Test.StoreHelper.stop_store()

    {:ok, _} =
      Archive.start_link(data_dir: System.tmp_dir!() <> "/test_cache_#{:rand.uniform(10000)}")

    # Create test sector
    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "test-sector",
        path: System.tmp_dir!() <> "/test_repo_#{:rand.uniform(10000)}"
      })

    # Create git repo
    File.mkdir_p!(sector.path)
    System.cmd("git", ["init"], cd: sector.path)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: sector.path)
    System.cmd("git", ["config", "user.name", "Test User"], cd: sector.path)
    File.write!(Path.join(sector.path, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: sector.path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: sector.path)

    {:ok, sector: sector}
  end

  test "get_research returns not_found for non-existent cache", %{sector: sector} do
    assert {:error, :not_found} = Cache.get_research(sector.id)
  end

  test "store_research and get_research work correctly", %{sector: sector} do
    research = %{structure: %{total_files: 1}}

    {:ok, cache} = Cache.store_research(sector.id, research)

    assert cache.sector_id == sector.id
    assert cache.research == research
    assert is_binary(cache.git_hash)

    {:ok, retrieved} = Cache.get_research(sector.id)
    assert retrieved.research == research
  end

  test "is_valid? returns true for fresh cache", %{sector: sector} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(sector.id, research)

    assert Cache.is_valid?(sector.id) == true
  end

  test "is_valid? returns false after git changes", %{sector: sector} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(sector.id, research)

    # Make a git change
    File.write!(Path.join(sector.path, "new_file.txt"), "content")
    System.cmd("git", ["add", "."], cd: sector.path)
    System.cmd("git", ["commit", "-m", "Add new file"], cd: sector.path)

    assert Cache.is_valid?(sector.id) == false
  end

  test "update_research merges with existing cache", %{sector: sector} do
    initial = %{structure: %{total_files: 1}}
    Cache.store_research(sector.id, initial)

    update = %{patterns: %{mvc: true}}
    {:ok, updated} = Cache.update_research(sector.id, update)

    expected = Map.merge(initial, update)
    assert updated.research == expected
  end

  test "invalidate removes cache and file index", %{sector: sector} do
    research = %{structure: %{total_files: 1}}
    file_index = [%{path: "test.ex", research: %{type: "module"}}]

    Cache.store_research(sector.id, research, file_index)

    # Verify cache exists
    assert {:ok, _} = Cache.get_research(sector.id)

    # Invalidate
    Cache.invalidate(sector.id)

    # Verify cache is gone
    assert {:error, :not_found} = Cache.get_research(sector.id)
  end

  test "get_file_research works with file index", %{sector: sector} do
    research = %{structure: %{total_files: 1}}
    file_research = %{type: "module", functions: 3}
    file_index = [%{path: "test.ex", research: file_research}]

    Cache.store_research(sector.id, research, file_index)

    {:ok, file_cache} = Cache.get_file_research(sector.id, "test.ex")
    assert file_cache.research == file_research
    assert file_cache.file_path == "test.ex"
  end

  test "get_file_research returns not_found for non-existent file", %{sector: sector} do
    research = %{structure: %{total_files: 1}}
    Cache.store_research(sector.id, research)

    assert {:error, :not_found} = Cache.get_file_research(sector.id, "nonexistent.ex")
  end
end
