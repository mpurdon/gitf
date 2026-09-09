defmodule GiTF.Missions.CompareTest do
  use GiTF.StoreCase

  alias GiTF.{Archive, Missions}
  alias GiTF.Major.PhaseCollector
  alias GiTF.Missions.Compare

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(%{name: "ab", goal: "g", status: "completed", artifacts: %{}, ops: []}, fields)
      )

    m
  end

  test "the collector tallies how each reply was parsed, per phase" do
    m = mission!(%{})
    wire_prompt = "## Output Format\n\n```wire\n%wire 1 triage\nT y | why\n```"
    json_reply = ~s({"complexity": "low", "skip_research": true})

    # Wire asked for, JSON came back: a card defect, counted as a fallback.
    PhaseCollector.collect("triage", json_reply, [], prompt: wire_prompt, mission_id: m.id)
    # JSON asked for, JSON came back.
    PhaseCollector.collect("triage", json_reply, [], prompt: "## Output Format", mission_id: m.id)
    # Nothing parseable.
    PhaseCollector.collect("triage", "no structure here", [], prompt: "x", mission_id: m.id)

    tally = Archive.get(:missions, m.id).notation_tally
    assert tally["triage"] == %{"json_fallback" => 1, "json" => 1, "parse_failed" => 1}
  end

  test "compare/2 puts the two profiles side by side with b's delta" do
    a = mission!(%{name: "a", wire: false, notation_tally: %{"triage" => %{"json" => 1}}})
    b = mission!(%{name: "b", wire: true, notation_tally: %{"triage" => %{"wire" => 1}}})

    assert {:ok, %{a: pa, b: pb, delta: d}} = Compare.compare(a.id, b.id)
    assert pa.wire == false and pb.wire == true
    assert pa.notation["json"] == 1 and pb.notation["wire"] == 1
    assert d.parse_failed == 0 and d.json_fallback == 0
    assert d.fix_rounds == 0
  end

  test "a mission pins its notation for the span of its dispatch" do
    refute GiTF.Wire.enabled?()
    assert GiTF.Wire.with_mission(%{wire: true}, fn -> GiTF.Wire.enabled?() end)
    refute GiTF.Wire.with_mission(%{wire: false}, fn -> GiTF.Wire.enabled?() end)
    refute GiTF.Wire.with_mission(%{}, fn -> GiTF.Wire.enabled?() end)
    refute GiTF.Wire.enabled?()

    {:ok, pinned} = Missions.create(%{goal: "g", wire: "true"})
    assert pinned.wire == true
  end
end
