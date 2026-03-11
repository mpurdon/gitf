defmodule GiTF.ProgressTest do
  use ExUnit.Case, async: true

  alias GiTF.Progress

  setup do
    # Ensure table exists (may already from Application.start)
    Progress.init()
    :ok
  end

  describe "update/2 and get/1" do
    test "stores and retrieves progress" do
      ghost_id = "ghost-progress-test-#{:erlang.unique_integer([:positive])}"
      Progress.update(ghost_id, %{tool: "Edit", file: "lib/foo.ex", message: "Editing file"})

      entry = Progress.get(ghost_id)
      assert entry.ghost_id == ghost_id
      assert entry.tool == "Edit"
      assert entry.file == "lib/foo.ex"
      assert entry.message == "Editing file"
      assert is_integer(entry.updated_at)

      # Cleanup
      Progress.clear(ghost_id)
    end
  end

  describe "all/0" do
    test "returns all entries" do
      id1 = "ghost-prog-all-#{:erlang.unique_integer([:positive])}"
      id2 = "ghost-prog-all-#{:erlang.unique_integer([:positive])}"

      Progress.update(id1, %{tool: "Read", message: "Reading"})
      Progress.update(id2, %{tool: "Write", message: "Writing"})

      all = Progress.all()
      ghost_ids = Enum.map(all, & &1.ghost_id)
      assert id1 in ghost_ids
      assert id2 in ghost_ids

      Progress.clear(id1)
      Progress.clear(id2)
    end
  end

  describe "clear/1" do
    test "removes an entry" do
      ghost_id = "ghost-clear-#{:erlang.unique_integer([:positive])}"
      Progress.update(ghost_id, %{tool: "Bash", message: "Running"})
      assert Progress.get(ghost_id) != nil

      Progress.clear(ghost_id)
      assert Progress.get(ghost_id) == nil
    end
  end

  describe "get/1 for missing" do
    test "returns nil for unknown ghost" do
      assert Progress.get("ghost-nonexistent-999") == nil
    end
  end
end
