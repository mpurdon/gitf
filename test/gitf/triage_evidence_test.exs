defmodule GiTF.TriageEvidenceTest do
  @moduledoc """
  Tests for the no-work-needed evidence bar (task #31).

  Triage's `bug_reproducible: false` verdict short-circuits the entire
  pipeline, so the evidence must be concrete. Prose-only justifications
  fall through to the regular pipeline.
  """
  use ExUnit.Case, async: true

  alias GiTF.Triage

  describe "strong_no_work_evidence?/1 — strong signals" do
    test "accepts a short commit SHA" do
      assert Triage.strong_no_work_evidence?("already fixed in abc1234")
    end

    test "accepts a full-length commit SHA" do
      assert Triage.strong_no_work_evidence?(
               "resolved by 1a2b3c4d5e6f7890abcdef1234567890abcdef12"
             )
    end

    test "accepts a file:line reference" do
      assert Triage.strong_no_work_evidence?("patched in lib/auth/session.ex:142")
    end

    test "accepts a file:line reference with extension variations" do
      assert Triage.strong_no_work_evidence?("see src/foo/bar.rs:200")
    end

    test "accepts a named test reference" do
      assert Triage.strong_no_work_evidence?(~s[covered by test "login flow redirects"])
    end

    test "accepts an RSpec/jest-style describe/it" do
      assert Triage.strong_no_work_evidence?("covered by it(\"does not double-submit\")")
    end
  end

  describe "strong_no_work_evidence?/1 — weak / missing" do
    test "rejects nil" do
      refute Triage.strong_no_work_evidence?(nil)
    end

    test "rejects empty string" do
      refute Triage.strong_no_work_evidence?("")
    end

    test "rejects bare prose with no citation" do
      refute Triage.strong_no_work_evidence?("I could not reproduce this on the latest main")
    end

    test "rejects a vague claim" do
      refute Triage.strong_no_work_evidence?("looks fine to me, no action needed")
    end

    test "rejects non-hex short strings" do
      refute Triage.strong_no_work_evidence?("issue XYZ1234")
    end

    test "rejects non-binary input defensively" do
      refute Triage.strong_no_work_evidence?(:not_a_string)
      refute Triage.strong_no_work_evidence?(42)
    end
  end
end
