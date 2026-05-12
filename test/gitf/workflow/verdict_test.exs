defmodule GiTF.Workflow.VerdictTest do
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Workflow.{Phase, Verdict}

  defp mission!(attrs \\ %{}) do
    {:ok, m} =
      Archive.insert(:missions, Map.merge(%{
        name: "test",
        goal: "x",
        status: "active",
        sector_id: "fe",
        current_phase: "research",
        artifacts: %{}
      }, attrs))

    m
  end

  defp put_artifact(mission, phase, artifact) do
    GiTF.Missions.store_artifact(mission.id, phase, artifact)
    Archive.get(:missions, mission.id)
  end

  describe "compute/2 — wait/advance basics" do
    test ":wait when no artifact yet" do
      m = mission!(%{current_phase: "research"})
      phase = %Phase{id: "research", next: "requirements"}
      assert Verdict.compute(m, phase) == :wait
    end

    test ":advance when artifact is present and phase is unconditional" do
      m = mission!(%{current_phase: "research"}) |> put_artifact("research", %{"summary" => "x"})
      phase = %Phase{id: "research", next: "requirements"}
      assert Verdict.compute(m, phase) == :advance
    end

    test ":fail when artifact is marked failed" do
      m = mission!() |> put_artifact("research", %{"status" => "failed"})
      phase = %Phase{id: "research", next: "requirements"}
      assert Verdict.compute(m, phase) == :fail
    end
  end

  describe "compute/2 — review verdict" do
    test ":pass when review.approved == true" do
      m = mission!(%{current_phase: "review"}) |> put_artifact("review", %{"approved" => true})
      phase = %Phase{id: "review", on_pass: "planning", on_fail: "design"}
      assert Verdict.compute(m, phase) == :pass
    end

    test ":fail when review.approved == false" do
      m = mission!(%{current_phase: "review"}) |> put_artifact("review", %{"approved" => false})
      phase = %Phase{id: "review", on_pass: "planning", on_fail: "design"}
      assert Verdict.compute(m, phase) == :fail
    end

    test ":wait when review artifact is missing approved field" do
      m = mission!(%{current_phase: "review"}) |> put_artifact("review", %{"comment" => "..."})
      phase = %Phase{id: "review", on_pass: "planning", on_fail: "design"}
      assert Verdict.compute(m, phase) == :wait
    end
  end

  describe "compute/2 — validation verdict" do
    test ":pass when verdict is 'pass'" do
      m =
        mission!(%{current_phase: "validation"})
        |> put_artifact("validation", %{"verdict" => "pass"})

      phase = %Phase{id: "validation", on_pass: "publish", on_fail: "implementation"}
      assert Verdict.compute(m, phase) == :pass
    end

    test ":pass when verdict is 'passed'" do
      m =
        mission!(%{current_phase: "validation"})
        |> put_artifact("validation", %{"verdict" => "passed"})

      phase = %Phase{id: "validation", on_pass: "publish", on_fail: "implementation"}
      assert Verdict.compute(m, phase) == :pass
    end

    test ":fail when verdict is 'fail'" do
      m =
        mission!(%{current_phase: "validation"})
        |> put_artifact("validation", %{"verdict" => "fail"})

      phase = %Phase{id: "validation", on_pass: "publish", on_fail: "implementation"}
      assert Verdict.compute(m, phase) == :fail
    end

    test "reads nested overall.verdict" do
      m =
        mission!(%{current_phase: "validation"})
        |> put_artifact("validation", %{"overall" => %{"verdict" => "pass"}})

      phase = %Phase{id: "validation", on_pass: "publish", on_fail: "implementation"}
      assert Verdict.compute(m, phase) == :pass
    end
  end

  describe "compute/2 — generic verdict-driven phase" do
    test "uses artifact.status for unknown phases" do
      m = mission!(%{current_phase: "custom"}) |> put_artifact("custom", %{"status" => "pass"})
      phase = %Phase{id: "custom", on_pass: "next", on_fail: "retry"}
      assert Verdict.compute(m, phase) == :pass
    end

    test "defaults to :advance for verdict-driven phase with neutral artifact" do
      m = mission!(%{current_phase: "custom"}) |> put_artifact("custom", %{"data" => "ok"})
      phase = %Phase{id: "custom", on_pass: "next", on_fail: "retry"}
      assert Verdict.compute(m, phase) == :advance
    end
  end
end
