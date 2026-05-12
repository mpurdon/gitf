defmodule GiTF.Vault.Renderer.GhostTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Renderer.Ghost

  defp ghost(attrs \\ %{}) do
    Map.merge(
      %{
        id: "ghost-abc",
        name: "calm-builder-935d",
        model: "claude-opus-4-7",
        tier: :opus,
        status: :running,
        sector_id: "frontend",
        op_id: "op-xyz",
        hired_at: ~U[2026-04-12 10:00:00Z],
        missions_completed: 47,
        specialties: [:implementation, :refactor]
      },
      attrs
    )
  end

  describe "render/2 — frontmatter" do
    test "emits required ghost fields" do
      out = Ghost.render(ghost())

      assert out =~ ~s(name: "calm-builder-935d")
      assert out =~ ~s(ghost_id: "ghost-abc")
      assert out =~ ~s(model: "claude-opus-4-7")
      assert out =~ ~s(tier: "opus")
      assert out =~ ~s(status: "running")
      assert out =~ ~s(current_op: "op-xyz")
      assert out =~ ~s(sector: "frontend")
      assert out =~ "missions_completed: 47"
    end

    test "formats trust score to two decimals" do
      out = Ghost.render(ghost(), trust_score: 0.834)
      assert out =~ "trust_score: 0.83"
    end

    test "skips trust_score when not provided" do
      out = Ghost.render(ghost())
      refute out =~ "trust_score:"
    end
  end

  describe "render/2 — sections" do
    test "headline uses the ghost name" do
      out = Ghost.render(ghost())
      assert out =~ "# calm-builder-935d"
    end

    test "renders Specialties when provided" do
      out = Ghost.render(ghost())
      assert out =~ "## Specialties"
      assert out =~ "- implementation"
      assert out =~ "- refactor"
    end

    test "omits Specialties when empty" do
      out = Ghost.render(ghost(%{specialties: []}))
      refute out =~ "## Specialties"
    end

    test "renders Recent missions as wikilinks" do
      missions = [
        %{id: "msn-1", name: "Fix login", status: "completed"},
        %{id: "msn-2", name: "Bump deps", status: "merged"}
      ]

      out = Ghost.render(ghost(), recent_missions: missions)

      assert out =~ "## Recent"
      assert out =~ "[[msn-1-fix-login]] · completed"
      assert out =~ "[[msn-2-bump-deps]] · merged"
    end

    test "omits Recent when no missions provided" do
      out = Ghost.render(ghost())
      refute out =~ "## Recent"
    end
  end
end
