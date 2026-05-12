defmodule GiTF.Phases.DefaultTest do
  use ExUnit.Case, async: true

  alias GiTF.Phases.Default
  alias GiTF.Workflow.Phase

  describe "behaviour conformance" do
    test "implements GiTF.Phase" do
      Code.ensure_loaded!(Default)
      assert function_exported?(Default, :start, 3)
      assert function_exported?(Default, :verdict, 1)
    end

    test "default verdict is :advance" do
      assert Default.verdict(%{}) == :advance
      assert Default.verdict(nil) == :advance
    end
  end

  describe "start/3 — dispatch hook" do
    test "errors out for an unknown phase id" do
      result = Default.start(%{id: "msn-test"}, %Phase{id: "phantom"}, %{})
      assert {:error, {:unknown_phase, "phantom"}} = result
    end
  end
end
