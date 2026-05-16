defmodule GiTF.Phases.ValidationTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Validation

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{name: "v", goal: "x", status: "active", sector_id: "fe", current_phase: "validation", artifacts: %{}, ops: []},
          attrs
        )
      )

    m
  end

  describe "verdict/1" do
    test ":pass when overall_verdict is 'pass'" do
      assert Validation.verdict(%{"overall_verdict" => "pass"}) == :pass
    end

    test ":pass when overall_verdict is 'passed'" do
      assert Validation.verdict(%{"overall_verdict" => "passed"}) == :pass
    end

    test ":fail when overall_verdict is 'fail'" do
      assert Validation.verdict(%{"overall_verdict" => "fail"}) == :fail
    end

    test ":fail when overall_verdict is 'failed'" do
      assert Validation.verdict(%{"overall_verdict" => "failed"}) == :fail
    end

    test ":inconclusive when overall_verdict is missing" do
      assert Validation.verdict(%{"requirements_met" => []}) == :inconclusive
    end

    test ":inconclusive on unrecognised verdict string" do
      assert Validation.verdict(%{"overall_verdict" => "unclear"}) == :inconclusive
    end

    test "falls back to top-level `verdict` field" do
      assert Validation.verdict(%{"verdict" => "pass"}) == :pass
    end

    test "falls back to nested `overall.verdict` path" do
      assert Validation.verdict(%{"overall" => %{"verdict" => "fail"}}) == :fail
    end

    test "accepts atom keys" do
      assert Validation.verdict(%{overall_verdict: "pass"}) == :pass
    end

    test ":inconclusive on non-map artifact" do
      assert Validation.verdict(nil) == :inconclusive
      assert Validation.verdict("pass") == :inconclusive
    end
  end

  describe "verdict/2 — rich mission-aware path" do
    test ":wait when there's no artifact yet" do
      m = insert_mission!(%{})
      assert Validation.verdict(m, nil) == :wait
    end

    test "pass + cross-check ok (impl op with meaningful changes) stamps requires_approval and returns :pass" do
      # validate_pass_against_diff/1 needs a done non-phase_job op with at
      # least one changed file that isn't under `.claude/`.
      ops = [
        %{
          phase_job: false,
          status: "done",
          changed_files: ["lib/foo.ex"],
          files_changed: 1
        }
      ]

      art = %{"overall_verdict" => "pass"}
      m = insert_mission!(%{ops: ops, artifacts: %{"validation" => art}})

      assert Validation.verdict(m, art) == :pass

      # Side effect: the artifact got `requires_approval` stamped.
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert Map.has_key?(reloaded.artifacts["validation"], "requires_approval")
    end

    test "pass + cross-check fails (no impl ops) overrides the artifact and falls to the fail branch" do
      art = %{"overall_verdict" => "pass"}
      m = insert_mission!(%{ops: [], artifacts: %{"validation" => art}})

      # With no impl ops, cross-check returns {:error, "no completed impl ops"},
      # the verdict overrides the artifact, then re-runs verdict on the
      # overridden artifact. With no fix-context attempts yet and no impl
      # op at all, the latest_impl is nil → stale? is false → fix_ctx not
      # exhausted → falls into the "attempt fixes" branch which returns :wait.
      assert Validation.verdict(m, art) == :wait

      stored = GiTF.Archive.get(:missions, m.id).artifacts["validation"]
      assert stored["overall_verdict"] == "fail"
      assert stored["cross_check_override"] =~ "no completed impl ops"
    end

    test "fail + fresh artifact + no fix-context attempts spent → :wait (attempts fixes)" do
      art = %{"overall_verdict" => "fail", "gaps" => ["x is wrong"]}
      m = insert_mission!(%{ops: [], artifacts: %{"validation" => art}})

      assert Validation.verdict(m, art) == :wait
    end
  end
end
