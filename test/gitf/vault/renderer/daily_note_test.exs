defmodule GiTF.Vault.Renderer.DailyNoteTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Renderer.DailyNote

  describe "render/1" do
    test "header uses the snapshot date" do
      out = DailyNote.render(%{date: ~D[2026-05-04]})
      assert out =~ "# 2026-05-04 — Standup"
    end

    test "frontmatter counts missions" do
      out =
        DailyNote.render(%{
          date: ~D[2026-05-04],
          missions: %{
            in_flight: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
            merged_today: [%{id: "x"}],
            failed_today: []
          }
        })

      assert out =~ "missions_in_flight: 3"
      assert out =~ "missions_merged_today: 1"
      assert out =~ "missions_failed_today: 0"
    end

    test "Yesterday section lists merged + failed missions" do
      out =
        DailyNote.render(%{
          date: ~D[2026-05-04],
          missions: %{
            merged_today: [%{id: "msn-1", name: "Fix login", sector_id: "fe"}],
            failed_today: [%{id: "msn-2", name: "Bump deps", sector_id: "fe"}]
          }
        })

      assert out =~ "## Yesterday"
      assert out =~ "✅ Merged [[msn-1-fix-login]]"
      assert out =~ "❌ [[msn-2-bump-deps]]"
    end

    test "Today section lists in-flight missions" do
      out =
        DailyNote.render(%{
          date: ~D[2026-05-04],
          missions: %{
            in_flight: [
              %{id: "msn-3", name: "Refactor", current_phase: "implementation"}
            ]
          }
        })

      assert out =~ "## Today"
      assert out =~ "[[msn-3-refactor]] · implementation"
    end

    test "Active employees lists active ghosts" do
      out =
        DailyNote.render(%{
          date: ~D[2026-05-04],
          ghosts: %{
            active: [
              %{name: "calm-builder-935d", op_id: "op-x"},
              %{name: "swift-validator-2c1f", op_id: nil}
            ]
          }
        })

      assert out =~ "## Active employees"
      assert out =~ "[[calm-builder-935d]] — op op-x"
      assert out =~ "[[swift-validator-2c1f]]"
    end

    test "Sectors lists kanban links with counts" do
      out =
        DailyNote.render(%{
          date: ~D[2026-05-04],
          sectors: [
            %{id: "frontend", todo: 1, doing: 2, review: 0, done: 12},
            %{id: "api-server", todo: 0, doing: 1, review: 1, done: 8}
          ]
        })

      assert out =~ "## Sectors"
      assert out =~ "[[Sectors/frontend/002_kanban|frontend]] — 1 / 2 / 0 / 12"
      assert out =~ "[[Sectors/api-server/002_kanban|api-server]] — 0 / 1 / 1 / 8"
    end

    test "Costs section formats currency" do
      out = DailyNote.render(%{date: ~D[2026-05-04], costs: %{today_usd: 4.20, week_usd: 17.18}})
      assert out =~ "Today $4.20 · This week $17.18"
    end

    test "omits empty sections" do
      out = DailyNote.render(%{date: ~D[2026-05-04]})
      refute out =~ "## Yesterday"
      refute out =~ "## Today"
      refute out =~ "## Active employees"
      refute out =~ "## Sectors"
      refute out =~ "## Costs"
    end
  end
end
