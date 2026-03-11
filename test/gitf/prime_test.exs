defmodule GiTF.PrimeTest do
  use ExUnit.Case, async: false

  alias GiTF.Prime
  alias GiTF.Store

  @tmp_dir System.tmp_dir!()

  setup do
    tmp_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  defp create_gitf_workspace do
    name = "gitf_prime_test_#{:erlang.unique_integer([:positive])}"
    gitf_root = Path.join(@tmp_dir, name)
    queen_dir = Path.join([gitf_root, ".gitf", "major"])
    File.mkdir_p!(queen_dir)

    queen_md = Path.join(queen_dir, "QUEEN.md")
    File.write!(queen_md, "# Major Instructions\n\nYou are the Major.\n")

    on_exit(fn -> File.rm_rf!(gitf_root) end)
    gitf_root
  end

  describe "prime(:major, gitf_root)" do
    test "returns QUEEN.md content plus section state summary" do
      gitf_root = create_gitf_workspace()

      assert {:ok, markdown} = Prime.prime(:major, gitf_root)
      assert markdown =~ "Major Instructions"
      assert markdown =~ "Current GiTF State"
      assert markdown =~ "Active Bees"
      assert markdown =~ "Pending Jobs"
    end

    test "returns error when QUEEN.md is missing" do
      tmp = Path.join(@tmp_dir, "gitf_prime_nomd_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, ".gitf"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :enoent} = Prime.prime(:major, tmp)
    end

    test "includes active ghost information in state summary" do
      gitf_root = create_gitf_workspace()

      # Create a working ghost
      {:ok, _bee} = Store.insert(:ghosts, %{name: "busy-ghost", status: "working"})

      {:ok, markdown} = Prime.prime(:major, gitf_root)
      assert markdown =~ "busy-ghost"
    end

    test "includes planning quests in state summary" do
      gitf_root = create_gitf_workspace()

      {:ok, quest} =
        Store.insert(:quests, %{name: "plan-quest", goal: "Plan something", status: "planning"})

      {:ok, markdown} = Prime.prime(:major, gitf_root)
      assert markdown =~ "plan-quest"
      assert markdown =~ quest.id
    end

    test "includes spec content for planning quests" do
      gitf_root = create_gitf_workspace()

      # Point GITF_PATH so Specs can find the .gitf dir
      System.put_env("GITF_PATH", gitf_root)
      on_exit(fn -> System.delete_env("GITF_PATH") end)

      {:ok, quest} =
        Store.insert(:quests, %{name: "spec-quest", goal: "Spec something", status: "planning"})

      GiTF.Specs.write(quest.id, "requirements", "# Requirements\n\n- FR-1: Do the thing")

      {:ok, markdown} = Prime.prime(:major, gitf_root)
      assert markdown =~ "Planning Specs: spec-quest"
      assert markdown =~ "Requirements"
      assert markdown =~ "FR-1: Do the thing"
    end

    test "truncates long spec content" do
      gitf_root = create_gitf_workspace()

      System.put_env("GITF_PATH", gitf_root)
      on_exit(fn -> System.delete_env("GITF_PATH") end)

      {:ok, quest} =
        Store.insert(:quests, %{name: "long-spec", goal: "Long spec", status: "planning"})

      long_content = Enum.map(1..150, fn i -> "Line #{i}" end) |> Enum.join("\n")
      GiTF.Specs.write(quest.id, "requirements", long_content)

      {:ok, markdown} = Prime.prime(:major, gitf_root)
      assert markdown =~ "(truncated"
      assert markdown =~ "Line 1"
      # Line 150 should be truncated away
      refute markdown =~ "Line 150"
    end
  end

  describe "prime(:ghost, ghost_id)" do
    test "returns a briefing for an existing ghost" do
      {:ok, ghost} = Store.insert(:ghosts, %{name: "worker-ghost", status: "starting"})

      assert {:ok, markdown} = Prime.prime(:ghost, ghost.id)
      assert markdown =~ "Bee Briefing"
      assert markdown =~ "worker-ghost"
      assert markdown =~ "Your Job"
      assert markdown =~ "Your Workspace"
      assert markdown =~ "Rules"
    end

    test "returns error for nonexistent ghost" do
      assert {:error, :bee_not_found} = Prime.prime(:ghost, "ghost-000000")
    end

    test "shows no job when ghost has no assignment" do
      {:ok, ghost} = Store.insert(:ghosts, %{name: "idle-ghost", status: "starting"})

      {:ok, markdown} = Prime.prime(:ghost, ghost.id)
      assert markdown =~ "No job assigned"
    end
  end
end
