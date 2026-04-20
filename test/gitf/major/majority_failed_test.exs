defmodule GiTF.Major.MajorityFailedTest do
  @moduledoc """
  Unit tests for `GiTF.Major.Orchestrator.majority_failed?/1`.

  Regression for a premature mission-fail bug: when a single impl op fails
  and its retry is still in flight (or schedulable), the original logic
  counted 1/1 = 100% failed and tripped `attempt_fallback_plan`, which then
  fell through to `fail_exhausted_quest`. The retry never got a chance.

  See commit history around this test for the specific real-world mission
  (msn-d0e6b3, GH-40).
  """
  use ExUnit.Case, async: true

  alias GiTF.Major.Orchestrator.Decisions

  # Minimal op shape sufficient for majority_failed?. Real ops carry more
  # fields but the function only inspects :id, :status, :retry_count,
  # :retry_of, :retried_as.
  defp op(attrs) do
    %{
      id: Map.fetch!(attrs, :id),
      status: Map.fetch!(attrs, :status),
      retry_count: Map.get(attrs, :retry_count, 0),
      retry_of: Map.get(attrs, :retry_of),
      retried_as: Map.get(attrs, :retried_as)
    }
  end

  test "empty input is not a majority failure" do
    refute Decisions.majority_failed?([])
  end

  test "all done is not a majority failure" do
    ops = [op(%{id: "a", status: "done"}), op(%{id: "b", status: "done"})]
    refute Decisions.majority_failed?(ops)
  end

  test "single failed op with no retry pending counts as terminal failure" do
    # retry_count is at max AND retried_as is nil — retries exhausted.
    ops = [op(%{id: "a", status: "failed", retry_count: 3, retried_as: nil})]
    assert Decisions.majority_failed?(ops)
  end

  test "failed op with retry in flight (retried_as set) does NOT count as terminal" do
    # This is the regression case from msn-d0e6b3.
    # Before fix: majority_failed?/1 returned true → fallback path →
    # fail_exhausted_quest. After fix: the failed-with-retry-in-flight op
    # is excluded from the terminal count, so total=0 and we return false.
    ops = [
      op(%{id: "orig", status: "failed", retry_count: 0, retried_as: "retry"}),
      op(%{id: "retry", status: "running", retry_of: "orig"})
    ]

    refute Decisions.majority_failed?(ops)
  end

  test "failed op with retry budget remaining and no retry yet does NOT count as terminal" do
    # Delayed-retry window: op failed, retry_count < max, retried_as still
    # nil (timer pending). Must not be treated as permanent.
    ops = [op(%{id: "a", status: "failed", retry_count: 0, retried_as: nil})]
    refute Decisions.majority_failed?(ops)
  end

  test "failed op resolved by successful retry sibling does NOT count as failure" do
    # Original failed; retry completed successfully. Sibling retry_of + done
    # puts the original in retried_ok. The retry itself is done → counted
    # as success, so total=1 done, 0 failed.
    ops = [
      op(%{id: "orig", status: "failed", retry_count: 0, retried_as: "retry"}),
      op(%{id: "retry", status: "done", retry_of: "orig"})
    ]

    refute Decisions.majority_failed?(ops)
  end

  test "two failed ops both with retries in flight does NOT count as majority" do
    ops = [
      op(%{id: "a", status: "failed", retry_count: 0, retried_as: "a2"}),
      op(%{id: "a2", status: "running", retry_of: "a"}),
      op(%{id: "b", status: "failed", retry_count: 0, retried_as: "b2"}),
      op(%{id: "b2", status: "running", retry_of: "b"})
    ]

    refute Decisions.majority_failed?(ops)
  end

  test "retry sibling that also failed with exhausted retries DOES count as terminal failure" do
    # Original failed, retry spawned and itself failed after exhausting
    # retries. This is a genuine exhaustion — should trip fallback.
    ops = [
      op(%{id: "orig", status: "failed", retry_count: 0, retried_as: "retry"}),
      op(%{
        id: "retry",
        status: "failed",
        retry_of: "orig",
        retry_count: 3,
        retried_as: nil
      })
    ]

    assert Decisions.majority_failed?(ops)
  end

  test "mix of done and failed-with-retry-in-flight: done-only counts, not majority" do
    ops = [
      op(%{id: "done1", status: "done"}),
      op(%{id: "orig", status: "failed", retry_count: 0, retried_as: "retry"}),
      op(%{id: "retry", status: "running", retry_of: "orig"})
    ]

    refute Decisions.majority_failed?(ops)
  end

  test "killed ops count as terminal failure when not retried" do
    # `killed` mirrors `GiTF.Ops.resolved?/2` semantics — an op that was
    # forcibly killed with no successful retry is a permanent failure for
    # the purpose of the fallback threshold.
    ops = [op(%{id: "a", status: "killed", retry_count: 3, retried_as: nil})]
    assert Decisions.majority_failed?(ops)

    # But if a retry sibling succeeded, the killed op is resolved.
    ops_resolved = [
      op(%{id: "a", status: "killed", retry_count: 0, retried_as: "retry"}),
      op(%{id: "retry", status: "done", retry_of: "a"})
    ]

    refute Decisions.majority_failed?(ops_resolved)
  end

  test "rejected ops behave like failed for the threshold" do
    ops = [
      op(%{id: "a", status: "rejected", retry_count: 3, retried_as: nil}),
      op(%{id: "b", status: "done"})
    ]

    # 1 failed / 2 terminal = 50%, not > 50%.
    refute Decisions.majority_failed?(ops)

    # Add a second rejected op: 2/3 > 50%.
    ops2 = ops ++ [op(%{id: "c", status: "rejected", retry_count: 3, retried_as: nil})]
    assert Decisions.majority_failed?(ops2)
  end
end
