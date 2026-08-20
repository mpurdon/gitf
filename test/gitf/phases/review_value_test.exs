defmodule GiTF.Phases.ReviewValueTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Review

  test "the same objection in different words fingerprints identically" do
    a = %{"summary" => "The drawer lacks a priority control.", "gaps" => ["priority missing"]}
    b = %{"summary" => "the DRAWER lacks a priority control!!", "gaps" => ["missing priority"]}

    assert Review.rejection_fingerprint(a) == Review.rejection_fingerprint(b)
  end

  test "a genuinely new objection fingerprints differently" do
    a = %{"summary" => "The drawer lacks a priority control."}
    b = %{"summary" => "Persistence does not survive an app restart."}

    refute Review.rejection_fingerprint(a) == Review.rejection_fingerprint(b)
  end

  test "repeating rejections exhaust the redesign budget immediately" do
    # Run 32 spent ~20 minutes in design<->review before reaching
    # implementation. Iteration is welcome; relitigating is not.
    {:ok, mission} =
      GiTF.Archive.insert(:missions, %{
        name: "r",
        goal: "g",
        artifacts: %{"review_rejections" => ["deadbeefdeadbeef", "deadbeefdeadbeef"]}
      })

    assert Review.repeating?(mission)
    assert Review.max_retries(mission, %GiTF.Workflow.Phase{id: "review", max_retries: 2}) == 0
  end

  test "distinct rejections keep the normal budget" do
    {:ok, mission} =
      GiTF.Archive.insert(:missions, %{
        name: "r2",
        goal: "g",
        artifacts: %{"review_rejections" => ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"]}
      })

    refute Review.repeating?(mission)
    assert Review.max_retries(mission, %GiTF.Workflow.Phase{id: "review", max_retries: 2}) > 0
  end
end
