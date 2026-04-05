defmodule GiTF.BriefTest do
  use GiTF.StoreCase

  alias GiTF.Brief
  alias GiTF.Archive

  @tmp_dir System.tmp_dir!()

  defp create_gitf_workspace do
    name = "gitf_prime_test_#{:erlang.unique_integer([:positive])}"
    gitf_root = Path.join(@tmp_dir, name)
    queen_dir = Path.join([gitf_root, ".gitf", "major"])
    File.mkdir_p!(queen_dir)

    queen_md = Path.join(queen_dir, "MAJOR.md")
    File.write!(queen_md, "# Major Instructions\n\nYou are the Major.\n")

    on_exit(fn -> File.rm_rf!(gitf_root) end)
    gitf_root
  end

  describe "brief(:major, gitf_root)" do
    test "returns MAJOR.md content plus section state summary" do
      gitf_root = create_gitf_workspace()

      assert {:ok, markdown} = Brief.brief(:major, gitf_root)
      assert markdown =~ "Major Instructions"
      assert markdown =~ "Current GiTF State"
      assert markdown =~ "Active Ghosts"
      assert markdown =~ "Pending Jobs"
    end

    test "returns error when MAJOR.md is missing" do
      tmp = Path.join(@tmp_dir, "gitf_prime_nomd_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, ".gitf"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :enoent} = Brief.brief(:major, tmp)
    end

    test "includes active ghost information in state summary" do
      gitf_root = create_gitf_workspace()

      # Create a working ghost
      {:ok, _bee} = Archive.insert(:ghosts, %{name: "busy-ghost", status: "working"})

      {:ok, markdown} = Brief.brief(:major, gitf_root)
      assert markdown =~ "busy-ghost"
    end

    test "includes planning missions in state summary" do
      gitf_root = create_gitf_workspace()

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "plan-mission",
          goal: "Plan something",
          status: "planning"
        })

      {:ok, markdown} = Brief.brief(:major, gitf_root)
      assert markdown =~ "plan-mission"
      assert markdown =~ mission.id
    end

    test "includes spec content for planning missions" do
      gitf_root = create_gitf_workspace()

      # Point GITF_PATH so Specs can find the .gitf dir
      System.put_env("GITF_PATH", gitf_root)
      on_exit(fn -> System.delete_env("GITF_PATH") end)

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "spec-mission",
          goal: "Spec something",
          status: "planning"
        })

      GiTF.Specs.write(mission.id, "requirements", "# Requirements\n\n- FR-1: Do the thing")

      {:ok, markdown} = Brief.brief(:major, gitf_root)
      assert markdown =~ "Planning Specs: spec-mission"
      assert markdown =~ "Requirements"
      assert markdown =~ "FR-1: Do the thing"
    end

    test "truncates long spec content" do
      gitf_root = create_gitf_workspace()

      System.put_env("GITF_PATH", gitf_root)
      on_exit(fn -> System.delete_env("GITF_PATH") end)

      {:ok, mission} =
        Archive.insert(:missions, %{name: "long-spec", goal: "Long spec", status: "planning"})

      long_content = Enum.map(1..150, fn i -> "Line #{i}" end) |> Enum.join("\n")
      GiTF.Specs.write(mission.id, "requirements", long_content)

      {:ok, markdown} = Brief.brief(:major, gitf_root)
      assert markdown =~ "(truncated"
      assert markdown =~ "Line 1"
      # Line 150 should be truncated away
      refute markdown =~ "Line 150"
    end
  end

  describe "brief(:ghost, ghost_id)" do
    test "returns a briefing for an existing ghost" do
      {:ok, ghost} = Archive.insert(:ghosts, %{name: "worker-ghost", status: "starting"})

      assert {:ok, markdown} = Brief.brief(:ghost, ghost.id)
      assert markdown =~ "Ghost Briefing"
      assert markdown =~ "worker-ghost"
      assert markdown =~ "Your Job"
      assert markdown =~ "Your Workspace"
      assert markdown =~ "Rules"
    end

    test "returns error for nonexistent ghost" do
      assert {:error, :bee_not_found} = Brief.brief(:ghost, "ghost-000000")
    end

    test "shows no op when ghost has no assignment" do
      {:ok, ghost} = Archive.insert(:ghosts, %{name: "idle-ghost", status: "starting"})

      {:ok, markdown} = Brief.brief(:ghost, ghost.id)
      assert markdown =~ "No op assigned"
    end
  end
end
