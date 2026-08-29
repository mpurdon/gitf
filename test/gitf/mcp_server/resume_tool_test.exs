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
