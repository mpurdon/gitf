defmodule GiTF.Dashboard.PlanLanesTest do
  @moduledoc """
  Lane assignment is what makes parallelism visible: ops in the same lane
  run concurrently, lane N+1 waits on lane N. The flat checklist hid this
  entirely — a plan with two independent lanes read as one long queue.
  """

  use ExUnit.Case, async: true

  alias GiTF.Dashboard.PlanLive

  defp op(name), do: %{"title" => name}

  test "independent ops share lane 0" do
    lanes = PlanLive.compute_lanes([{0, [], op("a")}, {1, [], op("b")}])

    assert [{0, items}] = lanes
    assert length(items) == 2
  end

  test "a chain makes one lane per link" do
    lanes =
      PlanLive.compute_lanes([
        {0, [], op("a")},
        {1, [0], op("b")},
        {2, [1], op("c")}
      ])

    assert [{0, [_]}, {1, [_]}, {2, [_]}] = lanes
  end

  test "a diamond puts the parallel middle in one lane" do
    # a → (b, c) → d: the shape run 22 planned — backend first, two
    # independent frontend ops in parallel, wiring last.
    lanes =
      PlanLive.compute_lanes([
        {0, [], op("backend")},
        {1, [0], op("settings-pane")},
        {2, [0], op("drawer")},
        {3, [1, 2], op("wiring")}
      ])

    assert [{0, [_]}, {1, middle}, {2, [_]}] = lanes
    assert length(middle) == 2
  end

  test "a dep pointing at a missing node is ignored, not fatal" do
    lanes = PlanLive.compute_lanes([{0, [99], op("a")}])

    assert [{0, [_]}] = lanes
  end

  test "a cycle degrades to finite depth rather than looping" do
    lanes =
      PlanLive.compute_lanes([
        {0, [1], op("a")},
        {1, [0], op("b")}
      ])

    # Both nodes land somewhere finite; the exact lane is unspecified.
    assert Enum.map(lanes, fn {_d, items} -> length(items) end) |> Enum.sum() == 2
  end

  test "empty plan yields no lanes" do
    assert PlanLive.compute_lanes([]) == []
  end
end
