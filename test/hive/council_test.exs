defmodule Hive.CouncilTest do
  use ExUnit.Case

  alias Hive.{Council, Store, Jobs, Quests}

  @store_dir Path.join(System.tmp_dir!(), "hive_council_test_store")

  setup do
    # Ensure a clean store for each test
    File.rm_rf!(@store_dir)
    File.mkdir_p!(@store_dir)

    case Store.start_link(data_dir: @store_dir) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> GenServer.stop(pid); Store.start_link(data_dir: @store_dir)
    end

    # Set HIVE_PATH so council_dir resolves
    hive_root = Path.join(System.tmp_dir!(), "hive_council_test_#{:erlang.unique_integer([:positive])}")
    hive_dir = Path.join(hive_root, ".hive")
    councils_dir = Path.join(hive_dir, "councils")
    File.mkdir_p!(councils_dir)
    System.put_env("HIVE_PATH", hive_root)

    on_exit(fn ->
      System.delete_env("HIVE_PATH")
      File.rm_rf!(hive_root)
    end)

    %{hive_root: hive_root, councils_dir: councils_dir}
  end

  describe "CRUD operations" do
    test "get returns {:error, :not_found} for missing council" do
      assert {:error, :not_found} = Council.get("cnl_nonexistent")
    end

    test "list returns empty when no councils exist" do
      assert Council.list() == []
    end

    test "delete returns {:error, :not_found} for missing council" do
      assert {:error, :not_found} = Council.delete("cnl_nonexistent")
    end

    test "council record can be inserted and retrieved directly" do
      record = %{
        name: "test-domain",
        domain: "Test Domain",
        status: "ready",
        experts: [
          %{key: "expert-one", name: "Expert One", focus: "Testing",
            contributions: ["Book 1"], philosophy: "Test all things"}
        ],
        tags: ["test"]
      }

      {:ok, council} = Store.insert(:councils, record)
      assert String.starts_with?(council.id, "cnl-")

      {:ok, fetched} = Council.get(council.id)
      assert fetched.name == "test-domain"
      assert fetched.domain == "Test Domain"
      assert fetched.status == "ready"
      assert length(fetched.experts) == 1
    end

    test "list returns all councils sorted by inserted_at" do
      {:ok, _} = Store.insert(:councils, %{name: "first", domain: "First", status: "ready", experts: []})
      {:ok, _} = Store.insert(:councils, %{name: "second", domain: "Second", status: "ready", experts: []})

      councils = Council.list()
      assert length(councils) == 2
    end

    test "list filters by status" do
      {:ok, _} = Store.insert(:councils, %{name: "ready-one", domain: "R1", status: "ready", experts: []})
      {:ok, _} = Store.insert(:councils, %{name: "gen-one", domain: "G1", status: "generating", experts: []})

      ready = Council.list(status: "ready")
      assert length(ready) == 1
      assert hd(ready).name == "ready-one"
    end

    test "delete removes council and files", %{councils_dir: councils_dir} do
      dir = Path.join(councils_dir, "to-delete")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "expert-one-expert.md"), "# Expert")

      {:ok, council} = Store.insert(:councils, %{
        name: "to-delete", domain: "To Delete", status: "ready", experts: []
      })

      assert :ok = Council.delete(council.id)
      assert {:error, :not_found} = Council.get(council.id)
      refute File.dir?(dir)
    end
  end

  describe "install_experts/3" do
    test "copies named expert files to worktree", %{councils_dir: councils_dir} do
      # Create council with files
      dir = Path.join(councils_dir, "install-test")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "alice-expert.md"), "# Alice Expert")
      File.write!(Path.join(dir, "bob-expert.md"), "# Bob Expert")
      File.write!(Path.join(dir, "charlie-expert.md"), "# Charlie Expert")

      {:ok, council} = Store.insert(:councils, %{
        name: "install-test", domain: "Install Test", status: "ready",
        experts: [
          %{key: "alice", name: "Alice"},
          %{key: "bob", name: "Bob"},
          %{key: "charlie", name: "Charlie"}
        ]
      })

      worktree = Path.join(System.tmp_dir!(), "hive_wt_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(worktree)
      on_exit(fn -> File.rm_rf!(worktree) end)

      # Install only alice and charlie
      assert :ok = Council.install_experts(council.id, ["alice", "charlie"], worktree)

      agents_dir = Path.join(worktree, ".claude/agents")
      assert File.exists?(Path.join(agents_dir, "alice-expert.md"))
      assert File.exists?(Path.join(agents_dir, "charlie-expert.md"))
      refute File.exists?(Path.join(agents_dir, "bob-expert.md"))
    end
  end

  describe "apply_to_quest/3" do
    test "creates review wave jobs chained after implementation jobs" do
      # Create a comb record
      {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})

      # Create quest and implementation job
      {:ok, quest} = Quests.create(%{goal: "Build dashboard", comb_id: comb.id})
      {:ok, impl_job} = Jobs.create(%{
        title: "Implement dashboard layout",
        quest_id: quest.id,
        comb_id: comb.id
      })

      # Create a ready council
      {:ok, council} = Store.insert(:councils, %{
        name: "web-design",
        domain: "Web UI Design",
        status: "ready",
        experts: [
          %{key: "alice", name: "Alice", focus: "Responsive design",
            contributions: ["Book A"], philosophy: "Respond to users"},
          %{key: "bob", name: "Bob", focus: "Mobile-first",
            contributions: ["Book B"], philosophy: "Mobile first"},
          %{key: "charlie", name: "Charlie", focus: "Accessibility",
            contributions: ["Book C"], philosophy: "Accessible to all"}
        ]
      })

      # Apply with wave_size: 2 → 2 waves (2, 1)
      assert {:ok, %{wave_count: 2, jobs_created: 2}} =
               Council.apply_to_quest(council.id, quest.id, wave_size: 2)

      # Quest should have council_id set
      quest_record = Store.get(:quests, quest.id)
      assert quest_record.council_id == council.id

      # Check review jobs were created
      all_jobs = Jobs.list(quest_id: quest.id)
      review_jobs = Enum.filter(all_jobs, fn j -> Map.get(j, :council_id) != nil end)

      assert length(review_jobs) == 2

      # Wave 1 should have alice and bob
      wave1 = Enum.find(review_jobs, fn j -> j.council_wave == 1 end)
      assert wave1 != nil
      assert wave1.council_experts == ["alice", "bob"]
      assert String.contains?(wave1.title, "[Wave 1: Alice, Bob]")
      assert String.contains?(wave1.title, "Review Implement dashboard layout")

      # Wave 2 should have charlie
      wave2 = Enum.find(review_jobs, fn j -> j.council_wave == 2 end)
      assert wave2 != nil
      assert wave2.council_experts == ["charlie"]
      assert String.contains?(wave2.title, "[Wave 2: Charlie]")

      # Check dependency chain: wave1 depends on impl_job, wave2 depends on wave1
      wave1_deps = Jobs.dependencies(wave1.id)
      assert length(wave1_deps) == 1
      assert hd(wave1_deps).id == impl_job.id

      wave2_deps = Jobs.dependencies(wave2.id)
      assert length(wave2_deps) == 1
      assert hd(wave2_deps).id == wave1.id
    end

    test "rejects application to non-ready council" do
      {:ok, comb} = Store.insert(:combs, %{name: "test-comb2", path: "/tmp/test2"})
      {:ok, quest} = Quests.create(%{goal: "Test quest", comb_id: comb.id})

      {:ok, council} = Store.insert(:councils, %{
        name: "not-ready", domain: "Not Ready", status: "generating", experts: []
      })

      assert {:error, {:not_ready, "generating"}} =
               Council.apply_to_quest(council.id, quest.id)
    end

    test "rejects application when quest has no implementation jobs" do
      {:ok, quest} = Quests.create(%{goal: "Empty quest"})

      {:ok, council} = Store.insert(:councils, %{
        name: "no-jobs", domain: "No Jobs", status: "ready",
        experts: [%{key: "ex", name: "Ex", focus: "F", contributions: [], philosophy: "P"}]
      })

      assert {:error, :no_implementation_jobs} =
               Council.apply_to_quest(council.id, quest.id)
    end
  end
end
