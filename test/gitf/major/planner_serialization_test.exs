defmodule GiTF.Major.PlannerSerializationTest do
  @moduledoc """
  The enforcement layer behind the ownership-split doctrine: parallel ghosts
  must never edit the same file (the msn-8e0eae conflict markers), but
  disjoint surfaces must not be flattened into one blob either (the plan
  page that read as one long queue).
  """

  use ExUnit.Case, async: true

  alias GiTF.Major.Planner

  defp spec(files, deps \\ []) do
    %{"title" => Enum.join(files, "+"), "target_files" => files, "depends_on_indices" => deps}
  end

  test "same file without a dependency gets serialized" do
    [_a, b] = Planner.serialize_shared_files([spec(["x.tsx"]), spec(["x.tsx"])])

    assert b["depends_on_indices"] == [0]
  end

  test "disjoint files stay independent — the parallelism survives" do
    [a, b] = Planner.serialize_shared_files([spec(["backend.rs"]), spec(["frontend.tsx"])])

    assert a["depends_on_indices"] == []
    assert b["depends_on_indices"] == []
  end

  test "an existing dependency path is not duplicated" do
    specs = [spec(["x.tsx"]), spec(["x.tsx"], [0]), spec(["x.tsx"], [1])]

    [_a, b, c] = Planner.serialize_shared_files(specs)

    assert b["depends_on_indices"] == [0]
    # c reaches 0 through 1 — no direct edge added.
    assert c["depends_on_indices"] == [1]
  end

  test "the run-22 diamond: shared wiring serializes, disjoint middles do not" do
    specs = [
      spec(["models.rs"]),
      spec(["SettingsView.tsx"], [0]),
      spec(["Drawer.tsx"], [0]),
      spec(["SettingsView.tsx", "Drawer.tsx"], [1])
    ]

    [_a, _b, c, d] = Planner.serialize_shared_files(specs)

    # b and c stay parallel (disjoint files, both after a).
    assert c["depends_on_indices"] == [0]
    # d already depends on 1 (SettingsView); it must ALSO gain 2 (Drawer),
    # or it races the drawer ghost on Drawer.tsx.
    assert Enum.sort(d["depends_on_indices"]) == [1, 2]
  end

  test "specs without target_files pass through untouched" do
    specs = [%{"title" => "a"}, %{"title" => "b"}]

    assert Planner.serialize_shared_files(specs) == specs
  end
end
