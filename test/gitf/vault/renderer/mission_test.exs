defmodule GiTF.Vault.Renderer.MissionTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Renderer.Mission

  defp base_mission(attrs \\ %{}) do
    Map.merge(
      %{
        id: "msn-abc123",
        name: "Fix login flow",
        goal: "Login returns 500 on Safari iOS — fix it",
        sector_id: "frontend",
        status: "implementation",
        current_phase: "implementation",
        priority: :high,
        inserted_at: ~U[2026-04-30 14:02:00Z]
      },
      attrs
    )
  end

  describe "render/2 — frontmatter" do
    test "emits required fields" do
      out = Mission.render(base_mission())
      assert out =~ "---\n"
      assert out =~ ~s(mission_id: "msn-abc123")
      assert out =~ ~s(sector: "frontend")
      assert out =~ ~s(status: "implementation")
      assert out =~ ~s(phase: "implementation")
      assert out =~ "priority: high"
      assert out =~ ~s(goal: "Login returns 500 on Safari iOS — fix it")
    end

    test "skips fields whose value is nil" do
      out = Mission.render(base_mission(%{current_phase: nil}))
      refute out =~ "phase:"
    end

    test "renders nested issue_ref as YAML" do
      m = base_mission(%{issue_ref: %{"source" => "sentry", "issue_id" => "9001"}})
      out = Mission.render(m)
      assert out =~ "issue_ref:\n"
      assert out =~ ~s(  issue_id: "9001")
      assert out =~ ~s(  source: "sentry")
    end

    test "truncates very long goals in frontmatter" do
      long_goal = String.duplicate("x ", 200)
      m = base_mission(%{goal: long_goal})
      out = Mission.render(m)
      [_, fm] = Regex.run(~r/^---\n(.+?)\n---/s, out)
      goal_line = fm |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "goal:"))
      assert byte_size(goal_line) <= 250
    end
  end

  describe "render/2 — phases checklist" do
    test "marks completed phases [x], current [~], rest [ ]" do
      out = Mission.render(base_mission(%{current_phase: "design"}))

      assert out =~ "- [x] research"
      assert out =~ "- [~] design"
      assert out =~ "- [ ] planning"
      assert out =~ "- [ ] implementation"
    end

    test "marks all phases [x] when mission is completed" do
      out = Mission.render(base_mission(%{status: "completed", current_phase: "scoring"}))

      assert out =~ "- [x] research"
      assert out =~ "- [x] implementation"
      assert out =~ "- [x] scoring"
      refute out =~ "[~]"
    end
  end

  describe "render/2 — sections" do
    test "includes Goal and Phases" do
      out = Mission.render(base_mission())
      assert out =~ "## Goal"
      assert out =~ "## Phases"
    end

    test "omits Activity when no activity provided" do
      out = Mission.render(base_mission())
      refute out =~ "## Activity"
    end

    test "renders Activity when events provided" do
      out =
        Mission.render(base_mission(),
          activity: [
            %{at: ~U[2026-04-30 14:05:00Z], text: "research started"},
            %{at: ~U[2026-04-30 14:13:00Z], text: "design completed"}
          ]
        )

      assert out =~ "## Activity"
      assert out =~ "research started"
      assert out =~ "design completed"
    end

    test "omits Linked when no linked slugs provided" do
      out = Mission.render(base_mission())
      refute out =~ "## Linked"
    end

    test "renders Linked with deduplicated wikilinks" do
      out = Mission.render(base_mission(), linked: ["auth-flow", "auth-flow", "indexes/api"])
      assert out =~ "- [[auth-flow]]"
      assert out =~ "- [[indexes/api]]"
      assert (out |> String.split("\n") |> Enum.count(&String.contains?(&1, "[[auth-flow]]"))) == 1
    end
  end

  describe "render/2 — output shape" do
    test "ends with exactly one trailing newline" do
      out = Mission.render(base_mission())
      assert String.ends_with?(out, "\n")
      refute String.ends_with?(out, "\n\n")
    end
  end
end
