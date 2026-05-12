defmodule GiTF.Phases.TriageTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Triage
  alias GiTF.Workflow
  alias GiTF.Workflow.{Advancer, Phase}

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(
          %{name: "t", goal: "x", status: "active", sector_id: "fe", current_phase: "triage", artifacts: %{}},
          attrs
        )
      )

    m
  end

  describe "verdict/1" do
    test "advances on a normal artifact, fails on a failed one" do
      assert Triage.verdict(%{"complexity" => "simple"}) == :advance
      assert Triage.verdict(%{"status" => "failed"}) == :fail
      assert Triage.verdict(nil) == :inconclusive
    end
  end

  describe "before_advance/3 side effects" do
    test "writes pipeline_mode from complexity" do
      m = insert_mission!(%{artifacts: %{"triage" => %{"complexity" => "complex"}}})
      :ok = Triage.before_advance(m, :advance, %{"complexity" => "complex"})
      assert GiTF.Archive.get(:missions, m.id).pipeline_mode == "full"

      m2 = insert_mission!(%{artifacts: %{"triage" => %{"complexity" => "simple"}}})
      :ok = Triage.before_advance(m2, :advance, %{"complexity" => "simple"})
      assert GiTF.Archive.get(:missions, m2.id).pipeline_mode == "fast"
    end

    test "stamps no_work_needed when bug isn't reproducible and evidence is strong" do
      art = %{"bug_reproducible" => false, "bug_evidence" => "fixed in commit a1b2c3d4e5f6"}
      m = insert_mission!(%{artifacts: %{"triage" => art}})
      :ok = Triage.before_advance(m, :advance, art)
      assert GiTF.Missions.get_artifact(m.id, "triage")["no_work_needed"] == true
    end

    test "does NOT stamp no_work_needed when evidence is weak" do
      art = %{"bug_reproducible" => false, "bug_evidence" => "I don't think this is a real issue"}
      m = insert_mission!(%{artifacts: %{"triage" => art}})
      :ok = Triage.before_advance(m, :advance, art)
      refute Map.has_key?(GiTF.Missions.get_artifact(m.id, "triage") || %{}, "no_work_needed")
    end

    test "no-op for non-advance verdicts / non-map artifacts" do
      m = insert_mission!(%{artifacts: %{"triage" => %{}}})
      assert :ok = Triage.before_advance(m, :fail, %{})
      assert :ok = Triage.before_advance(m, :advance, nil)
    end
  end

  describe "end-to-end via Advancer with a conditional-next triage workflow" do
    defp triage_workflow do
      %Workflow{
        name: "t",
        phases: [
          %Phase{
            id: "triage",
            handler: GiTF.Phases.Triage,
            next: [
              {"artifact.no_work_needed == true", "end"},
              {"artifact.skip_flags.skip_research != true", "research"},
              {"artifact.skip_flags.skip_design != true", "design"},
              {:else, "implementation"}
            ]
          },
          %Phase{id: "research", next: "design"},
          %Phase{id: "design", next: "implementation"},
          %Phase{id: "implementation", next: "end"}
        ]
      }
    end

    test "before_advance's no_work_needed stamp is visible to the conditional next (Advancer re-reads the artifact)" do
      art = %{"bug_reproducible" => false, "bug_evidence" => "lib/foo.ex:42 — already handled", "complexity" => "simple"}
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => art}})
      assert :complete = Advancer.decide(m, triage_workflow())
    end

    test "skip_flags route to the first unskipped phase" do
      art = %{"complexity" => "moderate", "skip_flags" => %{"skip_research" => true}}
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => art}})
      assert {:dispatch, "design"} = Advancer.decide(m, triage_workflow())
    end

    test "no skip flags → research" do
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => %{"complexity" => "complex"}}})
      assert {:dispatch, "research"} = Advancer.decide(m, triage_workflow())
    end

    test "everything skipped → implementation" do
      art = %{"skip_flags" => %{"skip_research" => true, "skip_design" => true}}
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => art}})
      assert {:dispatch, "implementation"} = Advancer.decide(m, triage_workflow())
    end
  end
end
