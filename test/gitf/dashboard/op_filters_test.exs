defmodule GiTF.Dashboard.OpFiltersTest do
  @moduledoc """
  The Ops chips disagreed with the list they filtered. On the operator's
  screenshot the chips read `Active 0 · Done 4 · Phase 7 · All 11`, and
  selecting **Done** rendered ten rows: the counts were computed over
  implementation ops while the filters ran over ALL ops, so `done` also
  listed the four validation and three simplify phase jobs.

  A chip is a label for a list. The invariant below — every chip's number
  equals the length of the list it selects — is the property that was
  violated, and it is asserted by looping over the filters so a future
  sixth one is covered by construction rather than by remembering.
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.MissionDetailLive

  # Every status chip, paired with the counts key it displays.
  @status_filters [
    {"active", :active},
    {"done", :done},
    {"running", :running},
    {"blocked", :blocked},
    {"failed", :failed},
    {"pending", :pending}
  ]

  defp op(id, status, opts \\ []) do
    base = %{id: id, title: id, status: status}
    if opts[:phase], do: Map.put(base, :phase_job, true), else: base
  end

  # The screenshot's shape: 4 implementation ops, 7 phase jobs, 11 total.
  defp mission_ops do
    [
      op("impl-done-1", "done"),
      op("impl-done-2", "done"),
      op("impl-done-3", "done"),
      op("impl-done-4", "done"),
      op("val-1", "done", phase: true),
      op("val-2", "done", phase: true),
      op("val-3", "done", phase: true),
      op("val-4", "done", phase: true),
      op("simplify-1", "done", phase: true),
      op("simplify-2", "done", phase: true),
      op("simplify-3", "running", phase: true)
    ]
  end

  # A busier mission so every status chip has something to count.
  defp mixed_ops do
    [
      op("a", "done"),
      op("b", "running"),
      op("c", "assigned"),
      op("d", "blocked"),
      op("e", "failed"),
      op("f", "pending"),
      op("g", "done", phase: true),
      op("h", "running", phase: true),
      op("i", "failed", phase: true),
      op("j", "blocked", phase: true)
    ]
  end

  defp ids(ops), do: ops |> Enum.map(& &1.id) |> Enum.sort()

  describe "the invariant: a chip's number is the length of its list" do
    test "holds for every status filter on the screenshot's mission" do
      for {filter, key} <- @status_filters do
        view = MissionDetailLive.op_view(mission_ops(), filter)

        assert length(view.visible) == view.counts[key],
               "#{filter}: chip said #{view.counts[key]}, list rendered #{length(view.visible)}"
      end
    end

    test "holds for every status filter on a mission with all statuses" do
      for {filter, key} <- @status_filters do
        view = MissionDetailLive.op_view(mixed_ops(), filter)

        assert length(view.visible) == view.counts[key],
               "#{filter}: chip said #{view.counts[key]}, list rendered #{length(view.visible)}"
      end
    end

    test "holds when there are no ops at all" do
      for {filter, key} <- @status_filters do
        view = MissionDetailLive.op_view([], filter)

        assert view.visible == []
        assert view.counts[key] == 0
      end
    end

    test "the counts do not depend on which filter is selected" do
      # The chips must read the same whichever one is active.
      counts = for {f, _} <- @status_filters, do: MissionDetailLive.op_view(mixed_ops(), f).counts

      assert Enum.uniq(counts) |> length() == 1
    end
  end

  describe "status filters exclude phase jobs" do
    test "done lists only implementation ops — this is the reported bug" do
      view = MissionDetailLive.op_view(mission_ops(), "done")

      assert view.counts.done == 4
      assert ids(view.visible) == ~w(impl-done-1 impl-done-2 impl-done-3 impl-done-4)
      refute Enum.any?(view.visible, &Map.get(&1, :phase_job))
    end

    test "running, blocked, failed and pending exclude phase jobs too" do
      for filter <- ~w(running blocked failed pending active) do
        view = MissionDetailLive.op_view(mixed_ops(), filter)

        refute Enum.any?(view.visible, &Map.get(&1, :phase_job)),
               "#{filter} leaked a phase job into an implementation-op chip"
      end
    end

    test "running covers assigned as well, and only impl ops" do
      view = MissionDetailLive.op_view(mixed_ops(), "running")

      assert ids(view.visible) == ~w(b c)
      assert view.counts.running == 2
    end
  end

  describe "phase and all" do
    test "phase returns exactly the phase jobs" do
      view = MissionDetailLive.op_view(mission_ops(), "phase")

      assert length(view.visible) == view.phase_count
      assert view.phase_count == 7
      assert Enum.all?(view.visible, &Map.get(&1, :phase_job))
    end

    test "all returns everything and matches the All chip" do
      view = MissionDetailLive.op_view(mission_ops(), "all")

      assert length(view.visible) == view.total
      assert view.total == 11
    end

    test "the chip set partitions: impl + phase = all" do
      view = MissionDetailLive.op_view(mission_ops(), "all")

      # 7 + 4 = 11, the model the operator's numbers already implied.
      assert view.impl_count + view.phase_count == view.total
    end
  end

  describe "active" do
    test "is everything unfinished, implementation only" do
      view = MissionDetailLive.op_view(mixed_ops(), "active")

      assert ids(view.visible) == ~w(b c d f)
      assert view.counts.active == 4
    end

    test "an op with an unfamiliar status is still visible under active" do
      # Deliberately the complement of done/failed rather than the union
      # of the known-active statuses, so no op becomes unreachable.
      ops = [op("a", "done"), op("weird", "quiesced")]
      view = MissionDetailLive.op_view(ops, "active")

      assert ids(view.visible) == ~w(weird)
      assert view.counts.active == 1
    end
  end

  describe "degenerate input" do
    test "an unknown filter falls back to all" do
      view = MissionDetailLive.op_view(mission_ops(), "no-such-filter")

      assert length(view.visible) == 11
    end

    test "phase_job false is an implementation op, not a phase job" do
      ops = [Map.put(op("a", "done"), :phase_job, false), op("b", "done", phase: true)]
      view = MissionDetailLive.op_view(ops, "done")

      assert ids(view.visible) == ~w(a)
    end

    test "an op with no status is counted nowhere but still appears under all" do
      ops = [%{id: "naked", title: "naked"}]

      # It must not raise — the old retry_all_failed used `&1.status`.
      for {filter, _} <- @status_filters do
        assert MissionDetailLive.op_view(ops, filter).visible |> is_list()
      end

      assert length(MissionDetailLive.op_view(ops, "all").visible) == 1
    end
  end
end
