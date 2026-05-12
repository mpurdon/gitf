defmodule GiTF.MissionsWorkflowTest do
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Missions

  describe "create/1 — workflow resolution" do
    test "defaults to 'standard' when nothing specified" do
      {:ok, m} = Missions.create(%{goal: "x"})
      assert m.workflow_id == "standard"
    end

    test "accepts explicit workflow_id" do
      {:ok, m} = Missions.create(%{goal: "x", workflow_id: "bug-fix"})
      assert m.workflow_id == "bug-fix"
    end

    test "accepts string-keyed workflow_id" do
      {:ok, m} = Missions.create(%{"goal" => "x", "workflow_id" => "refactor"})
      assert m.workflow_id == "refactor"
    end

    test "uses sector default when present" do
      {:ok, sector} =
        Archive.insert(:sectors, %{
          name: "fe",
          default_workflow: "frontend-flow"
        })

      {:ok, m} = Missions.create(%{goal: "x", sector_id: sector.id})
      assert m.workflow_id == "frontend-flow"
    end

    test "explicit workflow_id wins over sector default" do
      {:ok, sector} = Archive.insert(:sectors, %{name: "fe", default_workflow: "frontend"})

      {:ok, m} = Missions.create(%{goal: "x", sector_id: sector.id, workflow_id: "spike"})
      assert m.workflow_id == "spike"
    end
  end

  describe "switch_workflow/2" do
    setup do
      gitf_root =
        Path.join(System.tmp_dir!(), "missions-workflow-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(gitf_root, ".gitf"))
      File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

      prior = System.get_env("GITF_PATH")
      System.put_env("GITF_PATH", gitf_root)
      on_exit(fn -> if prior, do: System.put_env("GITF_PATH", prior), else: System.delete_env("GITF_PATH") end)
      on_exit(fn -> File.rm_rf!(gitf_root) end)

      :ok
    end

    test "persists the new workflow_id when the workflow exists in priv" do
      {:ok, m} = Missions.create(%{goal: "x"})
      assert m.workflow_id == "standard"

      assert {:ok, updated} = Missions.switch_workflow(m.id, "standard")
      assert updated.workflow_id == "standard"
    end

    test "errors when the workflow can't be resolved" do
      {:ok, m} = Missions.create(%{goal: "x"})
      assert {:error, _} = Missions.switch_workflow(m.id, "nonexistent")
    end

    test "errors when mission does not exist" do
      assert {:error, :mission_not_found} = Missions.switch_workflow("msn-ghost", "standard")
    end

    test "current_phase is preserved on switch" do
      {:ok, m} = Missions.create(%{goal: "x"})

      {:ok, _} =
        Archive.update(:missions, m.id, fn r -> Map.put(r, :current_phase, "implementation") end)

      assert {:ok, updated} = Missions.switch_workflow(m.id, "standard")
      assert updated.current_phase == "implementation"
    end
  end
end
