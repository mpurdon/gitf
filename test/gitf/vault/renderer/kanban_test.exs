defmodule GiTF.Vault.Renderer.KanbanTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Renderer.Kanban

  defp mission(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "Mission #{id}",
        goal: "Goal for #{id}",
        sector_id: "frontend",
        status: "active",
        priority: :normal,
        inserted_at: ~U[2026-05-04 12:00:00Z]
      },
      attrs
    )
  end

  describe "render/3" do
    test "produces Obsidian Kanban-compatible frontmatter" do
      out = Kanban.render("frontend", [])
      assert out =~ "kanban-plugin: basic"
      assert out =~ "sector: frontend"
      assert out =~ "%% kanban:settings"
    end

    test "always includes the four standard lanes in order" do
      out = Kanban.render("frontend", [])

      lanes =
        ~r/## (Todo|Doing|Review|Done)/
        |> Regex.scan(out, capture: :all_but_first)
        |> List.flatten()

      assert lanes == ["Todo", "Doing", "Review", "Done"]
    end

    test "buckets a pending mission into Todo" do
      out = Kanban.render("frontend", [mission("msn-1", %{status: "pending"})])
      [_, todo] = Regex.run(~r/## Todo\n\n(.*?)\n\n##/s, out)
      assert todo =~ "[[msn-1-mission-msn-1]]"
    end

    test "buckets an active mission into Doing" do
      out = Kanban.render("frontend", [mission("msn-2", %{status: "implementation"})])
      [_, doing] = Regex.run(~r/## Doing\n\n(.*?)\n\n##/s, out)
      assert doing =~ "[[msn-2-mission-msn-2]]"
    end

    test "buckets a review-state mission into Review" do
      out = Kanban.render("frontend", [mission("msn-3", %{status: "awaiting_approval"})])
      [_, review] = Regex.run(~r/## Review\n\n(.*?)\n\n##/s, out)
      assert review =~ "[[msn-3-mission-msn-3]]"
    end

    test "buckets completed missions into Done" do
      out = Kanban.render("frontend", [mission("msn-4", %{status: "completed"})])
      assert out =~ "## Done\n\n- [ ] [[msn-4-"
    end

    test "renders failed/closed missions in a separate Closed section" do
      missions = [
        mission("msn-f", %{status: "failed"}),
        mission("msn-c", %{status: "closed"})
      ]

      out = Kanban.render("frontend", missions)
      assert out =~ "## Closed"
      assert out =~ "[[msn-f-"
      assert out =~ "[[msn-c-"
    end

    test "closed_section: false suppresses the Closed lane" do
      out =
        Kanban.render("frontend", [mission("msn-f", %{status: "failed"})], closed_section: false)

      refute out =~ "## Closed"
    end

    test "sorts higher-priority missions to the top of their lane" do
      missions = [
        mission("msn-low", %{status: "pending", priority: :low}),
        mission("msn-crit", %{status: "pending", priority: :critical}),
        mission("msn-high", %{status: "pending", priority: :high})
      ]

      out = Kanban.render("frontend", missions)
      [_, todo_block] = Regex.run(~r/## Todo\n\n(.*?)\n\n##/s, out)
      lines = String.split(todo_block, "\n", trim: true)

      assert Enum.at(lines, 0) =~ "[[msn-crit-"
      assert Enum.at(lines, 1) =~ "[[msn-high-"
      assert Enum.at(lines, 2) =~ "[[msn-low-"
    end

    test "card line includes a goal summary" do
      out = Kanban.render("frontend", [mission("msn-x", %{goal: "Some goal text"})])
      assert out =~ "— Some goal text"
    end
  end
end
