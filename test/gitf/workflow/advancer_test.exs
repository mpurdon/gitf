defmodule GiTF.Workflow.AdvancerTest do
  use GiTF.StoreCase

  alias GiTF.Workflow
  alias GiTF.Workflow.{Advancer, Phase}

  defp build_workflow(phases) do
    %Workflow{name: "t", phases: phases}
  end

  defp insert_mission!(attrs \\ %{}) do
    {:ok, m} =
      GiTF.Archive.insert(:missions, Map.merge(%{
        name: "decision",
        goal: "x",
        status: "active",
        sector_id: "fe",
        current_phase: "research",
        artifacts: %{}
      }, attrs))

    m
  end

  describe "decide/2 — workflow lookup edge cases" do
    test "dispatches to entry phase when current_phase isn't in the workflow" do
      m = insert_mission!(%{current_phase: "implementation"})

      w =
        build_workflow([
          %Phase{id: "research", next: "design"},
          %Phase{id: "design", next: "end"}
        ])

      assert {:dispatch, "research"} = Advancer.decide(m, w)
    end

    test "errors out for an empty workflow with unknown current_phase" do
      m = insert_mission!(%{current_phase: "anything"})
      w = build_workflow([])
      assert {:error, :empty_workflow} = Advancer.decide(m, w)
    end
  end

  describe "decide/2 — operator gates" do
    defp gated_planning_workflow do
      build_workflow([
        %Phase{
          id: "planning",
          next: "implementation",
          gate: %{when: "mission.review_plan == true", action: :await_operator}
        },
        %Phase{id: "implementation", next: "end"}
      ])
    end

    test "blocks advance when the gate is active and uncleared" do
      m = insert_mission!(%{current_phase: "planning", review_plan: true})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "planning", %{"specs" => []})
      m = GiTF.Archive.get(:missions, m.id)

      assert {:wait, "planning"} = Advancer.decide(m, gated_planning_workflow())
    end

    test "advances once the operator clears the gate" do
      m = insert_mission!(%{current_phase: "planning", review_plan: true})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "planning", %{"specs" => []})
      {:ok, _} = GiTF.Missions.clear_gate(m.id, "planning")
      m = GiTF.Archive.get(:missions, m.id)

      assert {:dispatch, "implementation"} = Advancer.decide(m, gated_planning_workflow())
    end

    test "does not block when the gate condition is false" do
      m = insert_mission!(%{current_phase: "planning", review_plan: false})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "planning", %{"specs" => []})
      m = GiTF.Archive.get(:missions, m.id)

      assert {:dispatch, "implementation"} = Advancer.decide(m, gated_planning_workflow())
    end

    test "always-on gate (when: true) blocks until cleared" do
      w =
        build_workflow([
          %Phase{
            id: "review",
            next: "publish",
            gate: %{when: "true", action: :await_operator}
          },
          %Phase{id: "publish", next: "end"}
        ])

      m = insert_mission!(%{current_phase: "review"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"summary" => "x"})
      m = GiTF.Archive.get(:missions, m.id)

      assert {:wait, "review"} = Advancer.decide(m, w)

      {:ok, _} = GiTF.Missions.clear_gate(m.id, "review")
      m = GiTF.Archive.get(:missions, m.id)
      assert {:dispatch, "publish"} = Advancer.decide(m, w)
    end
  end

  describe "decide/2 — verdict + branching" do
    test ":wait when current phase has no artifact yet" do
      m = insert_mission!()
      w = build_workflow([%Phase{id: "research", next: "design"}])
      assert {:wait, "research"} = Advancer.decide(m, w)
    end

    test "{:dispatch, next} for unconditional phase with artifact present" do
      m = insert_mission!()
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "research", %{"summary" => "x"})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{id: "research", next: "design"},
          %Phase{id: "design", next: "end"}
        ])

      assert {:dispatch, "design"} = Advancer.decide(m, w)
    end

    test "follows on_pass for verdict-driven phase that passes" do
      m = insert_mission!(%{current_phase: "review"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"approved" => true})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{id: "review", on_pass: "planning", on_fail: "design"},
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      assert {:dispatch, "planning"} = Advancer.decide(m, w)
    end

    test "follows on_fail for verdict-driven phase that fails" do
      m = insert_mission!(%{current_phase: "review"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"approved" => false})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{id: "review", on_pass: "planning", on_fail: "design", max_retries: 3},
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      # Forward branch on fail bumps the SOURCE phase's retry counter so
      # subsequent re-entries eventually exhaust.
      assert {:retry, "review", "design"} = Advancer.decide(m, w)
    end

    test ":complete when next is :end" do
      m = insert_mission!(%{current_phase: "scoring"})
      {:ok, _} = GiTF.Missions.store_artifact(m.id, "scoring", %{"score" => 87})
      m = GiTF.Archive.get(:missions, m.id)

      w = build_workflow([%Phase{id: "scoring", next: "end"}])
      assert :complete = Advancer.decide(m, w)
    end

    test ":retries_exhausted when on_fail self-loops past max_retries" do
      m =
        insert_mission!(%{
          current_phase: "validation",
          phase_retries: %{"validation" => 3}
        })

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "validation", %{"verdict" => "fail"})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{id: "validation", on_pass: "end", on_fail: "validation", max_retries: 3}
        ])

      assert {:retries_exhausted, "validation"} = Advancer.decide(m, w)
    end

    test ":retry when on_fail self-loops within max_retries" do
      m =
        insert_mission!(%{
          current_phase: "validation",
          phase_retries: %{"validation" => 1}
        })

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "validation", %{"verdict" => "fail"})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{id: "validation", on_pass: "end", on_fail: "validation", max_retries: 3}
        ])

      assert {:retry, "validation", "validation"} = Advancer.decide(m, w)
    end

    test "handler.verdict/1 takes precedence over Workflow.Verdict.compute/2" do
      # Phases.Validation reads `overall_verdict`; the generic Verdict
      # module reads `verdict`. By emitting only `overall_verdict: "pass"`
      # we prove the handler path is being used (otherwise this would
      # route to on_fail because the generic computation would see "" and
      # return :fail).
      m = insert_mission!(%{current_phase: "validation"})

      {:ok, _} =
        GiTF.Missions.store_artifact(m.id, "validation", %{"overall_verdict" => "pass"})

      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{
            id: "validation",
            handler: GiTF.Phases.Validation,
            on_pass: "simplify",
            on_fail: "implementation",
            max_retries: 3
          },
          %Phase{id: "simplify", next: "end"},
          %Phase{id: "implementation", next: "validation"}
        ])

      assert {:dispatch, "simplify"} = Advancer.decide(m, w)
    end

    test "handler.before_advance/3 is invoked on advance" do
      # Observes Phases.Review.before_advance promoting the selected
      # variant onto the canonical "design" key on :pass.
      m = insert_mission!(%{current_phase: "review"})

      {:ok, _} =
        GiTF.Missions.store_artifact(m.id, "design_minimal", %{"approach" => "minimal"})

      {:ok, _} =
        GiTF.Missions.store_artifact(m.id, "design_normal", %{"approach" => "normal"})

      {:ok, _} =
        GiTF.Missions.store_artifact(m.id, "review", %{
          "approved" => true,
          "selected_design" => "minimal"
        })

      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{
            id: "review",
            handler: GiTF.Phases.Review,
            on_pass: "planning",
            on_fail: "design"
          },
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      assert {:dispatch, "planning"} = Advancer.decide(m, w)
      assert %{"approach" => "minimal"} = GiTF.Missions.get_artifact(m.id, "design")
    end

    test "handler.max_retries/2 overrides the YAML default" do
      # A handler that always reports a budget of 5 should keep retrying
      # past the phase's static `max_retries: 2`.
      m =
        insert_mission!(%{
          current_phase: "review",
          phase_retries: %{"review" => 4}
        })

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"approved" => false})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{
            id: "review",
            handler: GiTF.Workflow.AdvancerTest.GenerousReview,
            on_pass: "planning",
            on_fail: "design",
            max_retries: 2,
            on_exhausted: :fail
          },
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      # 4 < 5: still retrying despite YAML max_retries=2.
      assert {:retry, "review", "design"} = Advancer.decide(m, w)
    end

    test "handler.max_retries/2 raising falls back to the YAML default" do
      m =
        insert_mission!(%{
          current_phase: "review",
          phase_retries: %{"review" => 2}
        })

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"approved" => false})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{
            id: "review",
            handler: GiTF.Workflow.AdvancerTest.ExplodingReview,
            on_pass: "planning",
            on_fail: "design",
            max_retries: 2,
            on_exhausted: :fail
          },
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      # Callback raises → fall back to static max_retries: 2; 2 >= 2 exhausts.
      assert {:retries_exhausted, "review"} = Advancer.decide(m, w)
    end

    test "on_exhausted: :advance falls through to on_pass target" do
      m =
        insert_mission!(%{
          current_phase: "review",
          phase_retries: %{"review" => 2}
        })

      {:ok, _} = GiTF.Missions.store_artifact(m.id, "review", %{"approved" => false})
      m = GiTF.Archive.get(:missions, m.id)

      w =
        build_workflow([
          %Phase{
            id: "review",
            on_pass: "planning",
            on_fail: "design",
            max_retries: 2,
            on_exhausted: :advance
          },
          %Phase{id: "design", next: "review"},
          %Phase{id: "planning", next: "end"}
        ])

      # max_retries=2 is hit; on_exhausted: :advance routes via on_pass.
      assert {:dispatch, "planning"} = Advancer.decide(m, w)
    end
  end

  defmodule GenerousReview do
    @behaviour GiTF.Phase
    def start(_m, _p, _ctx), do: {:ok, :spawned}
    def verdict(%{"approved" => true}), do: :pass
    def verdict(%{"approved" => false}), do: :fail
    def verdict(_), do: :inconclusive
    def max_retries(_mission, _phase), do: 5
  end

  defmodule ExplodingReview do
    @behaviour GiTF.Phase
    def start(_m, _p, _ctx), do: {:ok, :spawned}
    def verdict(%{"approved" => true}), do: :pass
    def verdict(%{"approved" => false}), do: :fail
    def verdict(_), do: :inconclusive
    def max_retries(_mission, _phase), do: raise("boom")
  end
end
