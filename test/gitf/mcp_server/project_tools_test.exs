defmodule GiTF.MCPServer.ProjectToolsTest do
  use ExUnit.Case, async: false

  alias GiTF.MCPServer.{Handlers, Tools}

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_mcp_project_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sector} = GiTF.Archive.insert(:sectors, %{name: "repo", path: tmp})
    %{sector: sector}
  end

  describe "tool registry" do
    test "all project tools are exposed with confirm required on writes" do
      tools = Tools.all() |> Enum.into(%{}, fn t -> {t.name, t} end)

      for name <-
            ~w(create_project list_projects show_project approve_project
               update_project_roadmap pause_project resume_project) do
        assert Map.has_key?(tools, name), "expected MCP tool #{inspect(name)} to be registered"
      end

      for name <-
            ~w(create_project approve_project update_project_roadmap pause_project resume_project) do
        required = Map.get(tools[name].inputSchema, :required) || []
        assert "confirm" in required, "#{name} must require confirm"
      end
    end
  end

  describe "handlers" do
    test "create → show → approve → pause → resume round trip", %{sector: sector} do
      args = %{
        "name" => "review-app",
        "brief" => %{"vision" => "aggregate reviews"},
        "roadmap" => [
          %{"id" => "scaffold", "title" => "Scaffold", "goal" => "Set up skeleton"},
          %{"id" => "api", "title" => "API", "goal" => "Build it", "depends_on" => ["scaffold"]}
        ],
        "confirm" => true
      }

      assert {:ok, text} = Handlers.call("create_project", args)
      assert %{"id" => id, "status" => "draft"} = Jason.decode!(text)

      assert {:ok, text} = Handlers.call("show_project", %{"id" => id})
      assert %{"roadmap" => [_, _]} = Jason.decode!(text)

      assert {:ok, text} =
               Handlers.call("approve_project", %{
                 "id" => id,
                 "sector_id" => sector.id,
                 "confirm" => true
               })

      assert %{"status" => "active"} = Jason.decode!(text)

      assert {:ok, text} =
               Handlers.call("pause_project", %{"id" => id, "reason" => "hold", "confirm" => true})

      assert %{"status" => "paused"} = Jason.decode!(text)

      assert {:ok, text} = Handlers.call("resume_project", %{"id" => id, "confirm" => true})
      assert %{"status" => "active"} = Jason.decode!(text)
    end

    test "writes without confirm are refused" do
      assert {:error, msg} =
               Handlers.call("create_project", %{"name" => "x", "roadmap" => [%{}]})

      assert msg =~ "confirm"
    end

    test "update_project_roadmap validates the DAG" do
      {:ok, text} =
        Handlers.call("create_project", %{
          "name" => "p",
          "roadmap" => [%{"title" => "t", "goal" => "g"}],
          "confirm" => true
        })

      %{"id" => id} = Jason.decode!(text)

      assert {:error, msg} =
               Handlers.call("update_project_roadmap", %{
                 "id" => id,
                 "roadmap" => [
                   %{"id" => "a", "title" => "t", "goal" => "g", "depends_on" => ["b"]},
                   %{"id" => "b", "title" => "t", "goal" => "g", "depends_on" => ["a"]}
                 ],
                 "confirm" => true
               })

      assert msg =~ "cycle"
    end

    test "list_projects filters by status" do
      {:ok, _} =
        Handlers.call("create_project", %{
          "name" => "p1",
          "roadmap" => [%{"title" => "t", "goal" => "g"}],
          "confirm" => true
        })

      assert {:ok, text} = Handlers.call("list_projects", %{"status" => "draft"})
      assert [%{"name" => "p1"}] = Jason.decode!(text)

      assert {:ok, text} = Handlers.call("list_projects", %{"status" => "active"})
      assert [] = Jason.decode!(text)
    end
  end
end
