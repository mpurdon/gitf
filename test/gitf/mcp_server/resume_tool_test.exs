defmodule GiTF.MCPServer.ResumeToolTest do
  @moduledoc """
  The MCP is the primary control surface, so `resume_mission` has to be
  answerable there — including its refusals. Every error an operator can
  provoke must come back naming what to do instead, not as
  "internal error".
  """
  use GiTF.StoreCase

  alias GiTF.MCPServer.{Handlers, Tools}
  alias GiTF.{Archive, Missions}

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{name: "resume-mcp", path: "/tmp/gitf-no-such-repo"})

    %{sector: sector}
  end

  describe "tool registry" do
    test "resume_mission is registered as a write tool" do
      tool = Enum.find(Tools.all(), &(&1.name == "resume_mission"))

      assert tool, "expected resume_mission to be registered"
      assert "confirm" in (Map.get(tool.inputSchema, :required) || [])
      assert "id" in (Map.get(tool.inputSchema, :required) || [])
      # The provenance rule has to reach the caller, not just the source.
      assert tool.description =~ "Inherited state is a suspect"
      assert tool.description =~ "Resume IMPLIES start"
    end
  end

  describe "handler" do
    test "refuses without confirm" do
      assert {:error, msg} = Handlers.call("resume_mission", %{"id" => "msn-x"})
      assert msg =~ "confirm"
    end

    test "requires an id" do
      assert {:error, msg} = Handlers.call("resume_mission", %{"confirm" => true})
      assert msg =~ "id"
    end

    test "names the mission when it does not exist" do
      assert {:error, msg} =
               Handlers.call("resume_mission", %{"id" => "msn-nope", "confirm" => true})

      assert msg =~ "msn-nope"
    end

    test "explains that only a finished-badly mission can be resumed", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "live one", sector_id: sector.id})

      assert {:error, msg} =
               Handlers.call("resume_mission", %{"id" => mission.id, "confirm" => true})

      assert msg =~ "not failed or killed"
    end

    test "lists the supported phases when given an unsupported one", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "x", sector_id: sector.id})
      {:ok, _} = Missions.fail_quest(mission.id, "died")

      assert {:error, msg} =
               Handlers.call("resume_mission", %{
                 "id" => mission.id,
                 "from_phase" => "design",
                 "confirm" => true
               })

      assert msg =~ "validation"
    end

    test "says what to do when the sector clone is gone", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "x", sector_id: sector.id})
      {:ok, _} = Missions.fail_quest(mission.id, "died")

      assert {:error, msg} =
               Handlers.call("resume_mission", %{"id" => mission.id, "confirm" => true})

      assert msg =~ "sector clone"
    end
  end

  # The handler's contract changed after two timed-out calls produced four
  # missions: it now answers immediately and says whether it created
  # anything. These tests need a REAL clone, because the claim is about
  # what happens once a resume actually succeeds.
  describe "a resume that succeeds" do
    @git System.find_executable("git")

    setup do
      repo =
        Path.join(System.tmp_dir!(), "gitf_mcp_resume_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      git = fn args -> System.cmd(@git, args, cd: repo, stderr_to_stdout: true) end
      git.(["init", "-q", "-b", "main"])
      git.(["config", "user.email", "t@t.dev"])
      git.(["config", "user.name", "t"])
      File.write!(Path.join(repo, "README.md"), "base\n")
      git.(["add", "-A"])
      git.(["commit", "-qm", "base"])

      {:ok, sector} = Archive.insert(:sectors, %{name: "mcp-resume", path: repo})

      {:ok, parent} = Missions.create(%{goal: "ship it", sector_id: sector.id, status: "active"})

      # A real impl op → ghost → shell → worktree chain, because that is
      # what `fail_quest` archives and what the resume then cuts from.
      ghost_id = "ghost-#{:erlang.unique_integer([:positive])}"
      branch = "ghost/#{ghost_id}"
      worktree = Path.join([repo, "ghosts", ghost_id])
      System.cmd(@git, ["worktree", "add", "-q", worktree, "-b", branch], cd: repo)
      File.write!(Path.join(worktree, "feature.ex"), "defmodule Feature do\nend\n")
      System.cmd(@git, ["add", "-A"], cd: worktree)
      System.cmd(@git, ["commit", "-qm", "feature"], cd: worktree)

      {:ok, op} =
        GiTF.Ops.create(%{title: "Build", mission_id: parent.id, sector_id: sector.id})

      {:ok, ghost} =
        Archive.insert(:ghosts, %{id: ghost_id, name: "g", status: "stopped", op_id: op.id})

      {:ok, shell} =
        Archive.insert(:shells, %{
          sector_id: sector.id,
          ghost_id: ghost.id,
          worktree_path: worktree,
          branch: branch,
          status: "active",
          removed_at: nil
        })

      Archive.update(:ghosts, ghost.id, &Map.put(&1, :shell_id, shell.id))

      Archive.update(:ops, op.id, fn o ->
        Map.merge(o, %{
          status: "done",
          ghost_id: ghost.id,
          changed_files: ["feature.ex"],
          files_changed: 1
        })
      end)

      {:ok, _} = Missions.fail_quest(parent.id, "validation never converged")

      %{repo: repo, sector: sector, parent: parent}
    end

    defp resume!(id) do
      assert {:ok, json} = Handlers.call("resume_mission", %{"id" => id, "confirm" => true})
      Jason.decode!(json)
    end

    test "returns the child immediately, marked as still seeding", %{parent: parent} do
      body = resume!(parent.id)

      assert body["resumed_from"] == parent.id
      assert body["already_resumed"] == false
      assert body["seeding"] == true
      # The response is a receipt, not a finished job — say so.
      assert body["note"] =~ "background"
      assert body["status"] == "pending"
      assert body["resume_seeding"] == true
    end

    test "a repeat call returns the same mission and creates nothing", %{parent: parent} do
      first = resume!(parent.id)
      second = resume!(parent.id)

      assert second["id"] == first["id"]
      assert second["already_resumed"] == true
      assert second["note"] =~ "already has a live resume"

      children = Archive.filter(:missions, &(&1[:resumed_from] == parent.id))
      assert length(children) == 1
    end
  end

  describe "serialize_mission" do
    test "carries resume provenance so a post-mortem can see it", %{sector: sector} do
      {:ok, mission} = Missions.create(%{goal: "x", sector_id: sector.id})

      {:ok, _} =
        Missions.update(mission.id, %{
          resumed_from: "msn-parent",
          resumed_at_phase: "validation"
        })

      assert {:ok, json} = Handlers.call("show_mission", %{"id" => mission.id})
      decoded = Jason.decode!(json)

      assert decoded["resumed_from"] == "msn-parent"
      assert decoded["resumed_at_phase"] == "validation"
    end
  end
end
