defmodule GiTF.OpsFailureJudgeTest do
  @moduledoc """
  The judge is wired into `Ops.fail/2`, which is the one place a failure is
  classified. These tests cover the seam rather than the judge itself
  (`GiTF.Ghost.FailureClass.JudgeTest` does that): that a promoted class
  reaches the op, that the verdict is recorded even when it is not promoted,
  and — the one that matters most — that with the judge off the op is byte
  for byte what it was before this existed.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Ops
  alias GiTF.Test.ScriptedSystemOne

  setup do
    {:ok, sector} =
      Archive.insert(:sectors, %{name: "judge-test-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "judge-test-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    prev = %{
      client: Application.get_env(:gitf, :system_one_client),
      enabled: Application.get_env(:gitf, :system_one_enabled),
      judge: Application.get_env(:gitf, :failure_judge_enabled),
      key: System.get_env("GITF_SYSTEM_ONE_API_KEY")
    }

    Application.put_env(:gitf, :system_one_client, ScriptedSystemOne)

    on_exit(fn ->
      ScriptedSystemOne.stop()
      restore(:system_one_client, prev.client)
      restore(:system_one_enabled, prev.enabled)
      restore(:failure_judge_enabled, prev.judge)

      if prev.key,
        do: System.put_env("GITF_SYSTEM_ONE_API_KEY", prev.key),
        else: System.delete_env("GITF_SYSTEM_ONE_API_KEY")
    end)

    %{sector: sector, mission: mission}
  end

  defp restore(key, nil), do: Application.delete_env(:gitf, key)
  defp restore(key, value), do: Application.put_env(:gitf, key, value)

  defp arm_judge(reply) do
    Application.put_env(:gitf, :system_one_enabled, true)
    Application.put_env(:gitf, :failure_judge_enabled, true)
    System.put_env("GITF_SYSTEM_ONE_API_KEY", "test-key")
    {:ok, _} = ScriptedSystemOne.start(reply)
    :ok
  end

  defp failed_op(mission, sector, reason) do
    {:ok, op} = Ops.create(%{title: "judged op", mission_id: mission.id, sector_id: sector.id})
    {:ok, ghost} = Archive.insert(:ghosts, %{name: "ghost-judge", status: "starting"})
    {:ok, _} = Ops.assign(op.id, ghost.id)
    {:ok, _} = Ops.start(op.id)
    {:ok, _} = Ops.fail(op.id, reason)
    {:ok, op} = Ops.get(op.id)
    op
  end

  describe "with the judge off" do
    test "the op is exactly what it was before any of this", %{mission: m, sector: s} do
      op = failed_op(m, s, "ghost-985dec: Provision failed: :not_found")

      assert op.failure_classification == :unknown
      assert Map.get(op, :failure_judgement) == nil
      assert ScriptedSystemOne.calls() == []
    end
  end

  describe "with the judge on" do
    test "a confident verdict becomes the stored class", %{mission: m, sector: s} do
      arm_judge(ScriptedSystemOne.choice_reply("provider_error", 0.96))

      op = failed_op(m, s, "the upstream edge closed the connection mid-stream")

      assert op.failure_classification == :provider_error,
             "a promoted verdict must reach the op — Major reads this, not the reason text"

      assert op.failure_judgement.promoted
      assert op.failure_judgement.confidence == 0.96
    end

    test "the promoted class flows into the retry budgets", %{mission: m, sector: s} do
      # The point of promotion: a provider's bad day stops being charged to
      # the op's capability budget.
      arm_judge(ScriptedSystemOne.choice_reply("provider_error", 0.96))
      op = failed_op(m, s, "the upstream edge closed the connection mid-stream")

      assert GiTF.Ghost.FailureClass.provider_fault?(op.failure_classification)
      assert GiTF.Ghost.FailureClass.retryable?(op.failure_classification)
    end

    test "an advisory verdict is recorded and changes nothing", %{mission: m, sector: s} do
      arm_judge(ScriptedSystemOne.choice_reply("factory_defect", 1.0))

      op = failed_op(m, s, "ghost-985dec: Provision failed: :not_found")

      assert op.failure_classification == :unknown,
             "factory_defect is not in the taxonomy and must never be promoted into it"

      assert op.failure_judgement.verdict == "factory_defect"
      refute op.failure_judgement.promoted
    end

    test "a low-confidence verdict is recorded unpromoted", %{mission: m, sector: s} do
      arm_judge(ScriptedSystemOne.choice_reply("timeout", 0.4))

      op = failed_op(m, s, "the thing stopped responding, eventually")

      assert op.failure_classification == :unknown
      assert op.failure_judgement.verdict == "timeout"
      assert op.failure_judgement.confidence == 0.4
    end

    test "a failure the matcher already named is not sent out", %{mission: m, sector: s} do
      arm_judge(ScriptedSystemOne.choice_reply("bad_work", 1.0))

      op = failed_op(m, s, "sh: claude: command not found")

      assert op.failure_classification == :fatal
      assert Map.get(op, :failure_judgement) == nil
      assert ScriptedSystemOne.calls() == []
    end

    test "an unreachable judge leaves the op untouched", %{mission: m, sector: s} do
      arm_judge({:error, :rate_limited})

      op = failed_op(m, s, "something entirely novel went wrong")

      assert op.failure_classification == :unknown
      assert Map.get(op, :failure_judgement) == nil
      assert op.last_failure_reason =~ "entirely novel"
    end
  end
end
