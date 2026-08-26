defmodule GiTF.Phases.DesignTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Design

  defp insert_mission!(ops, extra \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "d",
            goal: "x",
            status: "active",
            sector_id: "fe",
            current_phase: "design",
            artifacts: %{},
            ops: ops
          },
          extra
        )
      )

    m
  end

  defp op(strategy, status),
    do: %{phase_job: true, phase: "design", strategy: strategy, status: status}

  describe "verdict/2" do
    test ":wait when no design ops have spawned yet" do
      m = insert_mission!([])
      assert Design.verdict(m, nil) == :wait
    end

    test ":wait while some design ops are still running" do
      m = insert_mission!([op("minimal", "done"), op("normal", "running")])
      assert Design.verdict(m, nil) == :wait
    end

    test ":advance when all design ops terminal with ≥1 done" do
      m = insert_mission!([op("minimal", "done"), op("normal", "done"), op("complex", "failed")])
      assert Design.verdict(m, nil) == :advance
    end

    test ":terminal_fail when all design ops failed" do
      m = insert_mission!([op("minimal", "failed"), op("normal", "failed")])
      assert Design.verdict(m, nil) == :terminal_fail
    end
  end

  describe "before_advance(:advance)" do
    test "single-variant case promotes the variant and stamps single_variant=true" do
      m = insert_mission!([op("minimal", "done"), op("normal", "failed")])
      Design.before_advance(m, :advance, nil)

      reloaded = GiTF.Archive.get(:missions, m.id)
      design_art = reloaded.artifacts["design"]
      assert design_art["single_variant"] == true
      assert design_art["selected_design"] == "minimal"
      assert design_art["variants"] == ["minimal"]
    end

    test "multi-variant case stamps single_variant=false" do
      m = insert_mission!([op("minimal", "done"), op("normal", "done"), op("complex", "done")])
      Design.before_advance(m, :advance, nil)

      reloaded = GiTF.Archive.get(:missions, m.id)
      design_art = reloaded.artifacts["design"]
      assert design_art["single_variant"] == false
      assert design_art["selected_design"] == "minimal"
      assert Enum.sort(design_art["variants"]) == ["complex", "minimal", "normal"]
    end
  end

  describe "terminal(:retries_exhausted)" do
    test "fails the mission with the legacy reason" do
      m = insert_mission!([op("minimal", "failed"), op("normal", "failed")])
      Design.terminal(m, :retries_exhausted, nil)
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.status == "failed"
      assert reloaded.failure_reason =~ "All design strategies failed"
    end
  end
end
