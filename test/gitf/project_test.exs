defmodule GiTF.ProjectTest do
  use ExUnit.Case, async: false

  alias GiTF.{Aramaki, Archive, Project}

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_project_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sector} = Archive.insert(:sectors, %{name: "repo", path: tmp})

    %{tmp: tmp, sector: sector}
  end

  # Diamond DAG: scaffold → {backend, frontend} → integrate
  defp diamond_attrs(sector_id) do
    %{
      name: "review-app",
      sector_id: sector_id,
      source: "api",
      brief: %{vision: "A review aggregation app"},
      roadmap: [
        %{id: "scaffold", title: "Scaffold app", goal: "Set up the skeleton"},
        %{id: "backend", title: "Backend", goal: "Build the API", depends_on: ["scaffold"]},
        %{id: "frontend", title: "Frontend", goal: "Build the UI", depends_on: ["scaffold"]},
        %{
          id: "integrate",
          title: "Integrate",
          goal: "Wire UI to API",
          depends_on: ["backend", "frontend"]
        }
      ]
    }
  end

  defp create_diamond(sector_id) do
    {:ok, project} = Project.create(diamond_attrs(sector_id))
    project
  end

  defp complete_item(project, item_id) do
    {:ok, mission} =
      GiTF.Missions.create(%{
        goal: "g",
        sector_id: project.sector_id,
        source: "project",
        source_project: %{project_id: project.id, item_id: item_id}
      })

    {:ok, _} = Project.attach_mission(project.id, item_id, mission.id)
    :ok = Project.on_mission_terminal(mission, :completed)
    {Project.get(project.id), mission}
  end

  describe "create/1" do
    test "creates a draft project with a normalized roadmap", %{sector: sector} do
      project = create_diamond(sector.id)

      assert project.status == "draft"
      assert length(project.roadmap) == 4
      assert Enum.all?(project.roadmap, &(&1.status == "pending" and is_nil(&1.mission_id)))
      assert project.brief.vision == "A review aggregation app"
    end

    test "accepts string keys and generates item ids" do
      {:ok, project} =
        Project.create(%{
          "name" => "p",
          "roadmap" => [%{"title" => "t", "goal" => "g"}]
        })

      assert [%{id: "item-1"}] = project.roadmap
    end

    test "rejects missing name and empty roadmap" do
      assert {:error, {:missing_fields, [:name]}} = Project.create(%{roadmap: [%{}]})
      assert {:error, {:missing_fields, [:roadmap]}} = Project.create(%{name: "p", roadmap: []})
    end

    test "rejects unknown dependencies" do
      assert {:error, {:unknown_dependencies, ["ghost"]}} =
               Project.create(%{
                 name: "p",
                 roadmap: [%{id: "a", title: "t", goal: "g", depends_on: ["ghost"]}]
               })
    end

    test "rejects dependency cycles" do
      assert {:error, :dependency_cycle} =
               Project.create(%{
                 name: "p",
                 roadmap: [
                   %{id: "a", title: "t", goal: "g", depends_on: ["b"]},
                   %{id: "b", title: "t", goal: "g", depends_on: ["a"]}
                 ]
               })
    end

    test "rejects duplicate item ids" do
      assert {:error, :duplicate_item_ids} =
               Project.create(%{
                 name: "p",
                 roadmap: [
                   %{id: "a", title: "t", goal: "g"},
                   %{id: "a", title: "t2", goal: "g2"}
                 ]
               })
    end
  end

  describe "lifecycle" do
    test "activate requires a sector" do
      {:ok, project} = Project.create(%{name: "p", roadmap: [%{title: "t", goal: "g"}]})
      assert {:error, :no_sector} = Project.activate(project.id)
    end

    test "draft → active → paused → active", %{sector: sector} do
      project = create_diamond(sector.id)

      assert {:ok, %{status: "active"}} = Project.activate(project.id)
      assert {:error, {:invalid_status, "active"}} = Project.activate(project.id)
      assert {:ok, %{status: "paused", paused_reason: "why"}} = Project.pause(project.id, "why")
      assert {:ok, %{status: "active", paused_reason: nil}} = Project.resume(project.id)
    end
  end

  describe "ready_items/1 and DAG advancement" do
    test "only the root is ready initially", %{sector: sector} do
      project = create_diamond(sector.id)
      assert [%{id: "scaffold"}] = Project.ready_items(project)
    end

    test "completing the root readies both branches; diamond join waits", %{sector: sector} do
      project = create_diamond(sector.id)
      {project, _} = complete_item(project, "scaffold")

      ready_ids = project |> Project.ready_items() |> Enum.map(& &1.id) |> Enum.sort()
      assert ready_ids == ["backend", "frontend"]

      {project, _} = complete_item(project, "backend")
      assert [%{id: "frontend"}] = Project.ready_items(project)

      {project, _} = complete_item(project, "frontend")
      assert [%{id: "integrate"}] = Project.ready_items(project)
    end

    test "project completes when all items complete", %{sector: sector} do
      project = create_diamond(sector.id)

      {project, _} = complete_item(project, "scaffold")
      {project, _} = complete_item(project, "backend")
      {project, _} = complete_item(project, "frontend")
      {project, _} = complete_item(project, "integrate")

      assert project.status == "completed"
      assert Enum.all?(project.roadmap, &(&1.status == "completed"))
    end

    test "a failed mission pauses the project and marks the item", %{sector: sector} do
      project = create_diamond(sector.id)
      {:ok, project} = Project.activate(project.id)

      {:ok, mission} =
        GiTF.Missions.create(%{
          goal: "g",
          sector_id: sector.id,
          source: "project",
          source_project: %{project_id: project.id, item_id: "scaffold"}
        })

      {:ok, _} = Project.attach_mission(project.id, "scaffold", mission.id)
      :ok = Project.on_mission_terminal(mission, {:failed, "validation exploded"})

      project = Project.get(project.id)
      assert project.status == "paused"
      assert project.paused_reason =~ "scaffold"
      assert Enum.find(project.roadmap, &(&1.id == "scaffold")).status == "failed"
    end
  end

  describe "mission_goal/2 context injection" do
    test "injects completed dependency outcomes into the goal", %{sector: sector} do
      project = create_diamond(sector.id)
      {project, mission} = complete_item(project, "scaffold")

      {:ok, _} =
        Archive.update(:missions, mission.id, fn m ->
          Map.put(m, :implementation_plan, "Used Phoenix 1.8 with LiveView")
        end)

      {:ok, _} =
        Archive.insert(:shells, %{mission_id: mission.id, branch: "ghost/gh-123"})

      backend = Enum.find(project.roadmap, &(&1.id == "backend"))
      goal = Project.mission_goal(Project.get(project.id), backend)

      assert goal =~ "Build the API"
      assert goal =~ "Context from completed prerequisite missions"
      assert goal =~ "Scaffold app"
      assert goal =~ "ghost/gh-123"
      assert goal =~ "Phoenix 1.8"
    end

    test "no context section without completed deps", %{sector: sector} do
      project = create_diamond(sector.id)
      scaffold = Enum.find(project.roadmap, &(&1.id == "scaffold"))

      goal = Project.mission_goal(project, scaffold)
      assert goal =~ "Set up the skeleton"
      refute goal =~ "Context from"
    end
  end

  describe "standard-workflow terminal path" do
    test "mark_user_visible_completed advances the roadmap item", %{sector: sector} do
      project = create_diamond(sector.id)
      {:ok, _} = Project.activate(project.id)
      assert Aramaki.advance_projects() == 1

      scaffold =
        Project.get(project.id).roadmap |> Enum.find(&(&1.id == "scaffold"))

      # The standard workflow path completes missions here — complete_quest
      # never runs (Phases.Scoring.terminal handles :complete).
      {:ok, _} = GiTF.Missions.mark_user_visible_completed(scaffold.mission_id)

      project = Project.get(project.id)
      assert Enum.find(project.roadmap, &(&1.id == "scaffold")).status == "completed"

      mission = Archive.get(:missions, scaffold.mission_id)
      assert mission.aramaki_notified == true

      # complete_quest afterwards (legacy tail) must not double-notify —
      # the dedupe flag short-circuits it.
      {:ok, _} = GiTF.Missions.complete_quest(scaffold.mission_id)
      assert Project.get(project.id).status == "active"
    end

    test "reconcile heals items whose missions finished silently", %{sector: sector} do
      project = create_diamond(sector.id)
      {:ok, _} = Project.activate(project.id)
      assert Aramaki.advance_projects() == 1

      scaffold = Project.get(project.id).roadmap |> Enum.find(&(&1.id == "scaffold"))

      # Simulate a missed notification: mission terminal, item still active.
      {:ok, _} =
        Archive.update(:missions, scaffold.mission_id, &Map.put(&1, :status, "completed"))

      # Next advancement pass heals the item AND unblocks both dependents.
      assert Aramaki.advance_projects() == 2

      statuses = Project.get(project.id).roadmap |> Map.new(&{&1.id, &1.status})

      assert statuses == %{
               "scaffold" => "completed",
               "backend" => "active",
               "frontend" => "active",
               "integrate" => "pending"
             }
    end
  end

  describe "Aramaki.advance_projects/0" do
    test "creates missions for ready items of active projects", %{sector: sector} do
      project = create_diamond(sector.id)
      {:ok, _} = Project.activate(project.id)

      assert Aramaki.advance_projects() == 1

      project = Project.get(project.id)
      scaffold = Enum.find(project.roadmap, &(&1.id == "scaffold"))
      assert scaffold.status == "active"
      assert is_binary(scaffold.mission_id)

      mission = Archive.get(:missions, scaffold.mission_id)
      assert mission.source == "project"
      assert mission.source_project == %{project_id: project.id, item_id: "scaffold"}
      assert mission.status == "pending"
      assert mission.sector_id == sector.id

      # Idempotent: item is active now, nothing new to create.
      assert Aramaki.advance_projects() == 0
    end

    test "ignores draft and paused projects", %{sector: sector} do
      _draft = create_diamond(sector.id)
      active = create_diamond(sector.id)
      {:ok, _} = Project.activate(active.id)
      {:ok, _} = Project.pause(active.id, "hold")

      assert Aramaki.advance_projects() == 0
    end

    test "completing a dependency unblocks dependents on the next pass", %{sector: sector} do
      project = create_diamond(sector.id)
      {:ok, _} = Project.activate(project.id)

      assert Aramaki.advance_projects() == 1
      project = Project.get(project.id)
      scaffold = Enum.find(project.roadmap, &(&1.id == "scaffold"))

      mission = Archive.get(:missions, scaffold.mission_id)
      :ok = Project.on_mission_terminal(mission, :completed)

      assert Aramaki.advance_projects() == 2

      statuses =
        Project.get(project.id).roadmap
        |> Map.new(&{&1.id, &1.status})

      assert statuses == %{
               "scaffold" => "completed",
               "backend" => "active",
               "frontend" => "active",
               "integrate" => "pending"
             }
    end
  end

  describe "Sector.create_new/2" do
    setup %{tmp: tmp} do
      workspace = Path.join(tmp, "workspace")
      File.mkdir_p!(Path.join(workspace, ".gitf"))
      File.write!(Path.join([workspace, ".gitf", "config.toml"]), "")
      original = System.get_env("GITF_PATH")
      System.put_env("GITF_PATH", workspace)

      on_exit(fn ->
        if original,
          do: System.put_env("GITF_PATH", original),
          else: System.delete_env("GITF_PATH")
      end)

      %{workspace: workspace}
    end

    test "creates and registers a greenfield sector", %{workspace: workspace} do
      assert {:ok, sector} = GiTF.Sector.create_new("fresh-app")

      assert sector.name == "fresh-app"
      assert sector.path == Path.join(workspace, "fresh-app")
      # Factory-owned greenfield repos auto-merge locally — project DAGs
      # need dependency work in the tree, not stranded on ghost/* branches.
      assert sector.sync_strategy == "auto_merge"
      assert File.dir?(Path.join(sector.path, ".git"))
      assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: sector.path)
      assert {"main\n", 0} = System.cmd("git", ["branch", "--show-current"], cd: sector.path)
    end

    test "rejects invalid names and existing paths", %{workspace: workspace} do
      assert {:error, :invalid_name} = GiTF.Sector.create_new("../escape")
      assert {:error, :invalid_name} = GiTF.Sector.create_new("")

      File.mkdir_p!(Path.join(workspace, "taken"))
      assert {:error, {:path_exists, _}} = GiTF.Sector.create_new("taken")

      assert {:ok, _} = GiTF.Sector.create_new("once")
      assert {:error, :name_taken} = GiTF.Sector.create_new("once")
    end
  end
end
