defmodule GiTF.Skills.MCPHandlersTest do
  @moduledoc """
  Exercises the MCP `list_skills`, `show_skill`, `update_skill`,
  `delete_skill`, `skills_stats` handlers directly.
  """

  use ExUnit.Case, async: false

  alias GiTF.MCPServer.Handlers
  alias GiTF.Skills

  setup do
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    :ok
  end

  defp decode({:ok, text}) do
    case Jason.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      other -> {:error, other}
    end
  end

  defp decode(other), do: other

  describe "list_skills" do
    test "returns active skills by default" do
      {:ok, active} = Skills.create(%{name: "a", description: "d", body: "b", scope: :global})
      {:ok, archived} = Skills.create(%{name: "x", description: "d", body: "b", scope: :global})
      Skills.update(archived.id, fn s -> Map.put(s, :status, :archived) end)

      assert {:ok, %{"count" => 1, "skills" => [skill]}} =
               decode(Handlers.call("list_skills", %{}))

      assert skill["id"] == active.id
    end

    test "can include archived" do
      {:ok, _} = Skills.create(%{name: "a", description: "d", body: "b", scope: :global})
      {:ok, archived} = Skills.create(%{name: "x", description: "d", body: "b", scope: :global})
      Skills.update(archived.id, fn s -> Map.put(s, :status, :archived) end)

      assert {:ok, %{"count" => 2}} =
               decode(Handlers.call("list_skills", %{"include_archived" => true}))
    end

    test "filters by scope" do
      {:ok, _g} = Skills.create(%{name: "g", description: "d", body: "b", scope: :global})

      {:ok, _s} =
        Skills.create(%{
          name: "s",
          description: "d",
          body: "b",
          scope: :sector,
          sector_id: "sec-X"
        })

      assert {:ok, %{"count" => 1, "skills" => [sk]}} =
               decode(Handlers.call("list_skills", %{"scope" => "sector"}))

      assert sk["name"] == "s"
    end
  end

  describe "show_skill" do
    test "returns full detail including body" do
      {:ok, s} =
        Skills.create(%{
          name: "n",
          description: "d",
          body: "full body content here",
          scope: :global
        })

      assert {:ok, detail} = decode(Handlers.call("show_skill", %{"id" => s.id}))
      assert detail["body"] == "full body content here"
      assert detail["id"] == s.id
    end

    test "returns error for missing skill" do
      assert {:error, msg} = Handlers.call("show_skill", %{"id" => "skill-nope"})
      assert msg =~ "not found"
    end
  end

  describe "update_skill" do
    test "requires confirm" do
      {:ok, s} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})

      assert {:error, msg} =
               Handlers.call("update_skill", %{"id" => s.id, "description" => "new"})

      assert msg =~ "confirm"
    end

    test "updates fields and clears embedding when body changes" do
      {:ok, s} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})
      Skills.update(s.id, fn skill -> Map.put(skill, :embedding, [1.0, 0.0]) end)

      assert {:ok, _} =
               Handlers.call("update_skill", %{
                 "id" => s.id,
                 "body" => "new body",
                 "confirm" => true
               })

      reloaded = Skills.get(s.id)
      assert reloaded.body == "new body"
      assert reloaded.embedding == nil
    end

    test "can archive via status update" do
      {:ok, s} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})

      assert {:ok, _} =
               Handlers.call("update_skill", %{
                 "id" => s.id,
                 "status" => "archived",
                 "confirm" => true
               })

      assert Skills.get(s.id).status == :archived
    end
  end

  describe "delete_skill" do
    test "requires confirm and actually deletes" do
      {:ok, s} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})

      assert {:error, _} = Handlers.call("delete_skill", %{"id" => s.id})

      assert {:ok, _} = Handlers.call("delete_skill", %{"id" => s.id, "confirm" => true})
      assert Skills.get(s.id) == nil
    end
  end

  describe "skills_stats" do
    test "returns scope + source breakdowns and top applied" do
      {:ok, g1} = Skills.create(%{name: "g1", description: "d", body: "b", scope: :global})
      {:ok, _g2} = Skills.create(%{name: "g2", description: "d", body: "b", scope: :global})

      {:ok, _s1} =
        Skills.create(%{
          name: "s1",
          description: "d",
          body: "b",
          scope: :sector,
          sector_id: "sec-A"
        })

      Skills.update(g1.id, fn s -> Map.put(s, :applied_count, 42) end)

      assert {:ok, stats} = decode(Handlers.call("skills_stats", %{}))
      assert stats["total"] == 3
      assert stats["active"] == 3
      assert stats["by_scope"]["global"] == 2
      assert stats["by_scope"]["sector"] == 1
      assert stats["by_source"]["human"] == 3

      [top | _] = stats["top_applied"]
      assert top["id"] == g1.id
    end
  end
end
