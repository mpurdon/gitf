defmodule GiTF.Dashboard.RequirementIndexTest do
  @moduledoc """
  A coverage list of bare ids ("FR-1 ✓") tells the reader nothing, so the
  design page joins ids to their descriptions. These pin that join.
  """
  use ExUnit.Case, async: true

  import GiTF.Dashboard.Helpers, only: [requirement_index: 1]

  test "indexes functional and non-functional requirements alike" do
    idx =
      requirement_index(%{
        "functional_requirements" => [%{"id" => "FR-1", "description" => "global default"}],
        "non_functional" => [%{"id" => "NFR-2", "description" => "no migration"}]
      })

    assert idx["FR-1"] == "global default"
    assert idx["NFR-2"] == "no migration"
  end

  test "skips entries missing an id or a description rather than crashing" do
    idx =
      requirement_index(%{
        "functional_requirements" => [
          %{"id" => "FR-1"},
          %{"description" => "orphan"},
          %{"id" => "FR-2", "description" => "kept"}
        ]
      })

    assert idx == %{"FR-2" => "kept"}
  end

  test "returns an empty index for a missing or empty artifact" do
    assert requirement_index(nil) == %{}
    assert requirement_index(%{}) == %{}
  end
end
