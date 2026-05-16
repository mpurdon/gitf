defmodule GiTF.Phases.SimplifyTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Simplify

  defp insert_mission!(ops, attrs \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{name: "s", goal: "x", status: "active", sector_id: "fe", current_phase: "simplify", artifacts: %{}, ops: ops},
          attrs
        )
      )

    m
  end

  defp op(strategy, status), do: %{phase: "simplify", strategy: strategy, status: status}

  describe "verdict/2" do
    test ":advance when the simplify artifact is already present (skipped path)" do
      m = insert_mission!([])
      assert Simplify.verdict(m, %{"skipped" => true}) == :advance
    end

    test ":wait when no ops and no artifact" do
      m = insert_mission!([])
      assert Simplify.verdict(m, nil) == :wait
    end

    test ":wait while some ops are running" do
      m = insert_mission!([op("naming", "done"), op("complexity", "running")])
      assert Simplify.verdict(m, nil) == :wait
    end

    test ":advance once all ops are terminal" do
      m = insert_mission!([op("naming", "done"), op("complexity", "done"), op("dedup", "failed")])
      assert Simplify.verdict(m, nil) == :advance
    end
  end

  describe "before_advance(:advance)" do
    test "writes the aggregate simplify artifact when none exists" do
      m = insert_mission!([op("naming", "done"), op("complexity", "done"), op("dedup", "failed")])
      Simplify.before_advance(m, :advance, nil)

      reloaded = GiTF.Archive.get(:missions, m.id)
      art = reloaded.artifacts["simplify"]
      assert Enum.sort(art["agents"]) == ["complexity", "naming"]
      assert is_binary(art["completed_at"])
    end

    test "leaves an existing artifact alone (skip path)" do
      existing = %{"skipped" => true, "agents" => [], "skipped_reason" => "triage_complexity_low"}
      m = insert_mission!([], %{artifacts: %{"simplify" => existing}})
      Simplify.before_advance(m, :advance, existing)
      assert GiTF.Archive.get(:missions, m.id).artifacts["simplify"] == existing
    end
  end
end
