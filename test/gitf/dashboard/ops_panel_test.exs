defmodule GiTF.Dashboard.OpsPanelTest do
  @moduledoc """
  The Ops card opened on the "active" filter, which is 0 on a finished
  mission, and rendered "No ops created yet" about a mission with thirteen of
  them — the primary panel of the primary object page, wrong by default.
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.MissionDetailLive, as: Detail

  test "a finished mission opens on everything" do
    for status <- ~w(completed failed cancelled closed killed) do
      assert Detail.default_op_filter(%{status: status}) == "all",
             "#{status} should open on all ops"
    end
  end

  test "a mission still working opens on what is active" do
    for status <- ~w(active pending implementation validation awaiting_approval) do
      assert Detail.default_op_filter(%{status: status}) == "active"
    end
  end

  test "the default filter is never empty for a finished mission that has ops" do
    ops = [
      %{id: "op-1", status: "done", phase_job: true, phase: "triage"},
      %{id: "op-2", status: "done", phase_job: false}
    ]

    view = Detail.op_view(ops, Detail.default_op_filter(%{status: "completed"}))
    assert view.visible != []
    assert length(view.visible) == view.total
  end
end
