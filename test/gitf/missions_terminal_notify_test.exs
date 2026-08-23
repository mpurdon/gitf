defmodule GiTF.MissionsTerminalNotifyTest do
  @moduledoc """
  A mission reached `status: "failed"` with `current_phase: "validation"` and
  no failure_reason — a half-finished transition that took a path other than
  fail_quest. Two things went wrong: nobody fired its terminal notification,
  so the reviewer who asked for the change was never told the run ended; and
  the Janitor's phase filter kept matching it, re-advancing it every 3
  minutes forever.
  """
  use GiTF.StoreCase

  alias GiTF.Missions

  defp mission(attrs) do
    {:ok, m} = Missions.create(%{goal: "g", sector_id: "sec-x"})
    {:ok, updated} = GiTF.Archive.update(:missions, m.id, &Map.merge(&1, attrs))
    updated
  end

  test "normalises a terminal mission left in a non-terminal phase" do
    m = mission(%{status: "failed", current_phase: "validation", source: "pr_review"})

    :ok = Missions.ensure_terminal_notified(m)

    reloaded = GiTF.Archive.get(:missions, m.id)
    assert reloaded[:current_phase] == "completed"
    assert reloaded[:aramaki_notified] == true
  end

  test "is idempotent — a repaired record cannot double-post" do
    m = mission(%{status: "failed", current_phase: "validation", source: "pr_review"})

    :ok = Missions.ensure_terminal_notified(m)
    notified = GiTF.Archive.get(:missions, m.id)

    # Second pass sees the flag and does nothing.
    :ok = Missions.ensure_terminal_notified(notified)
    assert GiTF.Archive.get(:missions, m.id)[:aramaki_notified] == true
  end

  test "leaves a running mission alone" do
    m = mission(%{status: "active", current_phase: "validation", source: "pr_review"})

    :ok = Missions.ensure_terminal_notified(m)

    reloaded = GiTF.Archive.get(:missions, m.id)
    assert reloaded[:current_phase] == "validation"
    refute reloaded[:aramaki_notified]
  end

  test "a terminal mission already in a terminal phase keeps its phase" do
    m = mission(%{status: "completed", current_phase: "completed", source: "pr_review"})

    :ok = Missions.ensure_terminal_notified(m)
    assert GiTF.Archive.get(:missions, m.id)[:current_phase] == "completed"
  end

  test "missions from other sources are safe to sweep" do
    # Non-Aramaki sources must not raise on the notify path.
    m = mission(%{status: "failed", current_phase: "validation", source: nil})
    assert Missions.ensure_terminal_notified(m) == :ok
  end
end
