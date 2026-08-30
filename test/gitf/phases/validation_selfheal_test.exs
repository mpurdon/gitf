defmodule GiTF.Phases.ValidationSelfHealTest do
  @moduledoc """
  msn-05bebd: the mission's phase said `validation`, no validation op had
  ever been created, and the verdict answered `:wait` to every Janitor
  tick for hours. "Wait" is only an answer when somebody is coming.

  These tests pin the distinction the verdict now draws — in flight vs
  stranded — and the bound on how many times it will try to fix it
  itself. The respawn's own side effects (a real `start_validation`) are
  isolated inside `respawn_validation/1`, so what is asserted here is the
  DECISION and its bookkeeping, not the ghost.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Ops}
  alias GiTF.Phases.Validation

  defp mission!(attrs \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "heal",
            goal: "x",
            status: "active",
            sector_id: "no-such-sector",
            current_phase: "validation",
            artifacts: %{},
            ops: []
          },
          attrs
        )
      )

    m
  end

  defp phase_op!(mission, phase, status) do
    {:ok, op} =
      Ops.create(%{
        title: "#{phase} phase",
        mission_id: mission.id,
        sector_id: mission.sector_id
      })

    Archive.update(:ops, op.id, fn o ->
      Map.merge(o, %{phase_job: true, phase: phase, status: status})
    end)

    op
  end

  defp validation_ops(mission_id) do
    Ops.list(mission_id: mission_id)
    |> Enum.filter(&(&1[:phase] == "validation"))
  end

  defp respawns(mission_id), do: Archive.get(:missions, mission_id)[:validation_respawns]

  describe "a validation ghost IS in flight" do
    for status <- ~w(pending assigned running) do
      test "#{status} validation op → plain :wait, nothing respawned" do
        m = mission!()
        phase_op!(m, "validation", unquote(status))

        assert Validation.verdict(m, nil) == :wait
        refute respawns(m.id)
        assert length(validation_ops(m.id)) == 1
      end
    end
  end

  describe "nobody is coming" do
    test "a validation phase with no validation op at all respawns and counts the attempt" do
      m = mission!()

      assert Validation.verdict(m, nil) == :wait
      assert respawns(m.id) == 1

      # The point of the whole fix: the Janitor's next tick now has
      # something that ACTS, instead of the same silence to wait on.
      assert validation_ops(m.id) != []
    end

    test "a COMPLETED validation op does not count as in flight" do
      # The wedge shape exactly: the phase op finished (or was reaped)
      # without ever writing an artifact.
      m = mission!()
      phase_op!(m, "validation", "done")

      assert Validation.verdict(m, nil) == :wait
      assert respawns(m.id) == 1
    end

    test "an in-flight op for a DIFFERENT phase does not count" do
      m = mission!()
      phase_op!(m, "implementation", "running")

      assert Validation.verdict(m, nil) == :wait
      assert respawns(m.id) == 1
    end

    test "a successful respawn ends the healing — the next poll just waits" do
      m = mission!()

      assert Validation.verdict(m, nil) == :wait
      assert respawns(m.id) == 1

      # The op the respawn created is now in flight, so the second poll is
      # an ordinary wait and spends no further attempt.
      {:ok, current} = GiTF.Missions.get(m.id)
      assert Validation.verdict(current, nil) == :wait
      assert respawns(m.id) == 1
      assert length(validation_ops(m.id)) == 1
    end

    test "past the cap it stops respawning, alerts, and holds" do
      handler = "selfheal-alert-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:gitf, :alert, :raised],
        fn _e, _m, meta, _ -> send(test_pid, {:alert, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      m = mission!(%{validation_respawns: 3})

      assert Validation.verdict(m, nil) == :wait
      # The counter does NOT climb past the cap — no further attempt was made.
      assert respawns(m.id) == 3

      assert_receive {:alert, %{type: :mission_stalled, message: message}}
      assert message =~ m.id
      assert message =~ "HELD"
    end
  end

  describe "the self-heal stays out of the way" do
    test "a mission that is not in the validation phase is left alone" do
      m = mission!(%{current_phase: "implementation"})

      assert Validation.verdict(m, nil) == :wait
      refute respawns(m.id)
    end

    test "a validation artifact arriving clears the spent attempts" do
      m =
        mission!(%{
          validation_respawns: 2,
          artifacts: %{"validation" => %{"overall_verdict" => "fail", "gaps" => ["g"]}}
        })

      assert Validation.verdict(m, nil) == :wait
      assert respawns(m.id) == 0
    end
  end
end
