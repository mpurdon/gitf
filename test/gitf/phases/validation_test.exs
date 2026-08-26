defmodule GiTF.Phases.ValidationTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Validation

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "v",
            goal: "x",
            status: "active",
            sector_id: "fe",
            current_phase: "validation",
            artifacts: %{},
            ops: []
          },
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

  describe "verdict/2 — tournament mode" do
    test ":wait while any variant is still in flight" do
      m =
        insert_mission!(%{
          impl_variants: ["v1", "v2"],
          artifacts: %{
            "validation_v1" => %{"overall_verdict" => "pass"}
          }
        })

      assert Validation.verdict(m, nil) == :wait
    end

    test "picks winner + stamps mission + promotes artifact when all variants validated" do
      v1_artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [%{"met" => true}],
        "gaps" => ["minor nit"]
      }

      v2_artifact = %{
        "overall_verdict" => "pass",
        "requirements_met" => [%{"met" => true}],
        "gaps" => []
      }

      ops = [
        %{phase_job: false, status: "done", changed_files: ["lib/v2.ex"], files_changed: 1}
      ]

      m =
        insert_mission!(%{
          impl_variants: ["v1", "v2"],
          ops: ops,
          artifacts: %{"validation_v1" => v1_artifact, "validation_v2" => v2_artifact}
        })

      # v2 wins (zero gaps vs v1's one gap). Verdict falls through into
      # the single-variant pass path which stamps requires_approval.
      assert Validation.verdict(m, nil) == :pass

      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.winning_variant == "v2"
      assert reloaded.artifacts["validation"]["overall_verdict"] == "pass"
      assert Map.has_key?(reloaded.artifacts["validation"], "requires_approval")
    end

    test ":terminal_fail when every variant was disqualified by cross-check" do
      m =
        insert_mission!(%{
          impl_variants: ["v1", "v2"],
          artifacts: %{
            "validation_v1" => %{"cross_check_override" => "no commits"},
            "validation_v2" => %{"cross_check_override" => "all .claude/"}
          }
        })

      assert Validation.verdict(m, nil) == :terminal_fail
    end
  end

  describe "infrastructure_failure?/1" do
    test "TOOL MISSING output is infrastructure, not the ghost's code" do
      # Runs 27-29: a missing toolchain / full disk / starved probe lock
      # burned fix attempts on trees that were never actually judged.
      assert Validation.infrastructure_failure?(%{
               "exec_validation_output" =>
                 "TOOL MISSING on host (exit 127) — the validation command's toolchain is not installed"
             })

      assert Validation.infrastructure_failure?(%{
               "failures" => %{
                 "output" =>
                   "only 900MB disk free; this is an infrastructure problem, not a code problem"
               }
             })
    end

    test "a real code failure is NOT treated as infrastructure" do
      refute Validation.infrastructure_failure?(%{
               "exec_validation_output" =>
                 "error TS2322: Type 'string' is not assignable to type 'number'"
             })

      refute Validation.infrastructure_failure?(%{"summary" => "the drawer crashed on open"})
      refute Validation.infrastructure_failure?(nil)
      refute Validation.infrastructure_failure?(%{})
    end

    test "the sentinel is found in gaps too — run 7 hid it there" do
      # msn-4fda11: the LLM validator paraphrased its summary ("host
      # toolchain error") but quoted the sentinel verbatim inside gaps.
      assert Validation.infrastructure_failure?(%{
               "summary" => "validation failed with a host toolchain error",
               "gaps" => [
                 "Execution validation FAILED per ground truth: `TOOL MISSING on host (exit 127)`"
               ]
             })
    end
  end

  describe "exec_infra_failure?/1" do
    test "reads the factory's own out-of-band verdict" do
      assert Validation.exec_infra_failure?(%{
               artifacts: %{
                 "exec_validation" => %{"status" => "fail", "infra_failure" => true}
               }
             })

      # A genuine code failure keeps the fix loop armed.
      refute Validation.exec_infra_failure?(%{
               artifacts: %{
                 "exec_validation" => %{"status" => "fail", "infra_failure" => false}
               }
             })

      # A pass or no verdict at all must never suppress fixes.
      refute Validation.exec_infra_failure?(%{
               artifacts: %{"exec_validation" => %{"status" => "pass"}}
             })

      refute Validation.exec_infra_failure?(%{artifacts: %{}})
      refute Validation.exec_infra_failure?(%{})
      refute Validation.exec_infra_failure?(nil)
    end
  end
end
