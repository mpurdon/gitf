defmodule GiTF.Ghost.FailureClass.JudgeTest do
  @moduledoc """
  The judge's whole contract is that it can only ever make things better.

  It sees failures the signature matcher could not name, and the answer it
  falls back to is the one the factory would have reached without it. So the
  tests that matter most here are the negative ones: that a regex hit is
  never revisited, that being off or unreachable is indistinguishable from
  the judge not existing, and that a verdict below its threshold changes
  nothing.
  """
  use ExUnit.Case, async: false

  alias GiTF.Ghost.FailureClass.Judge
  alias GiTF.Test.ScriptedSystemOne

  setup do
    prev_client = Application.get_env(:gitf, :system_one_client)
    prev_enabled = Application.get_env(:gitf, :system_one_enabled)
    prev_judge = Application.get_env(:gitf, :failure_judge_enabled)
    prev_key = System.get_env("GITF_SYSTEM_ONE_API_KEY")

    Application.put_env(:gitf, :system_one_client, ScriptedSystemOne)
    Application.put_env(:gitf, :system_one_enabled, true)
    Application.put_env(:gitf, :failure_judge_enabled, true)
    System.put_env("GITF_SYSTEM_ONE_API_KEY", "test-key")

    on_exit(fn ->
      ScriptedSystemOne.stop()
      restore(:system_one_client, prev_client)
      restore(:system_one_enabled, prev_enabled)
      restore(:failure_judge_enabled, prev_judge)

      if prev_key,
        do: System.put_env("GITF_SYSTEM_ONE_API_KEY", prev_key),
        else: System.delete_env("GITF_SYSTEM_ONE_API_KEY")
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:gitf, key)
  defp restore(key, value), do: Application.put_env(:gitf, key, value)

  describe "it never second-guesses the signature matcher" do
    test "a named class is returned untouched and costs nothing" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("bad_work", 1.0))

      for class <- [:fatal, :provider_error, :timeout, :no_changes, :blocked] do
        assert Judge.refine(class, "anything at all") == :skip, inspect(class)
      end

      assert ScriptedSystemOne.calls() == [],
             "the judge called out for a failure the matcher had already named"
    end
  end

  describe "when it cannot help, nothing changes" do
    test "switched off, it does not call and does not answer" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("factory_defect", 1.0))
      Application.put_env(:gitf, :failure_judge_enabled, false)

      assert Judge.refine(:unknown, "Provision failed: :not_found") == :skip
      assert ScriptedSystemOne.calls() == []
    end

    test "with no API key it is off however the flags read" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("factory_defect", 1.0))
      System.delete_env("GITF_SYSTEM_ONE_API_KEY")

      refute Judge.enabled?()
      assert Judge.refine(:unknown, "Provision failed: :not_found") == :skip
    end

    test "an unreachable judge is indistinguishable from an absent one" do
      # The path that actually runs when the box is throttled or offline.
      for error <- [{:error, :rate_limited}, {:error, :timeout}, {:error, {:http_error, 500}}] do
        {:ok, _} = ScriptedSystemOne.start(error)
        assert Judge.refine(:unknown, "something novel broke") == :skip, inspect(error)
      end
    end

    test "a malformed answer is declined rather than trusted" do
      {:ok, _} = ScriptedSystemOne.start({:ok, %{answers: %{}, model: "jev", usage: %{}}})
      assert Judge.refine(:unknown, "something novel broke") == :skip
    end

    test "an empty reason is not worth asking about" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("unknown", 1.0))

      assert Judge.refine(:unknown, "") == :skip
      assert Judge.refine(:unknown, "   ") == :skip
      assert Judge.refine(:unknown, nil) == :skip
      assert ScriptedSystemOne.calls() == []
    end
  end

  describe "promotion" do
    test "a confident verdict in the taxonomy is promoted" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("provider_error", 0.97))

      assert {:ok, judgement} = Judge.refine(:unknown, "upstream returned a 503 from the edge")
      assert judgement.class == :provider_error
      assert judgement.promoted
      assert judgement.verdict == "provider_error"
      assert judgement.confidence == 0.97
    end

    test "the same verdict below threshold is recorded but not promoted" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("provider_error", 0.6))

      assert {:ok, judgement} = Judge.refine(:unknown, "upstream returned a 503 from the edge")
      assert judgement.class == nil
      refute judgement.promoted

      assert judgement.verdict == "provider_error",
             "an unpromoted verdict must still be recorded, or the pilot measures nothing"
    end

    test "fatal needs more confidence than the rest, because it ends the op" do
      # 0.8 clears the default threshold and must NOT clear fatal's.
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("fatal", 0.8))
      assert {:ok, not_promoted} = Judge.refine(:unknown, "the credential store said no")
      assert not_promoted.class == nil

      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("provider_error", 0.8))
      assert {:ok, promoted} = Judge.refine(:unknown, "the credential store said no")
      assert promoted.class == :provider_error

      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("fatal", 0.95))
      assert {:ok, high} = Judge.refine(:unknown, "the credential store said no")
      assert high.class == :fatal
    end

    test "the advisory classes are never promoted, at any confidence" do
      # These have no counterpart in the taxonomy. Promoting one would put a
      # value into :failure_classification that retryable?/1 has never seen.
      for verdict <- ~w(factory_defect bad_work unknown) do
        {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply(verdict, 1.0))

        assert {:ok, judgement} = Judge.refine(:unknown, "ghost-985dec: Provision failed")
        assert judgement.class == nil, "#{verdict} was promoted into the taxonomy"
        assert judgement.verdict == verdict
      end
    end

    test "every promotable verdict maps to a class the taxonomy already knows" do
      # Guards against promoting a string that FailureClass has no clause for:
      # retryable?/1 and provider_fault?/1 would both silently take their
      # catch-all branch.
      for verdict <- ~w(provider_error timeout fatal no_changes blocked) do
        {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply(verdict, 1.0))

        assert {:ok, %{class: class}} = Judge.refine(:unknown, "some novel failure text")
        assert is_atom(class)
        assert is_boolean(GiTF.Ghost.FailureClass.retryable?(class))
        assert is_boolean(GiTF.Ghost.FailureClass.provider_fault?(class))
      end
    end
  end

  describe "what it is asked" do
    test "the failure text is the state, and the options are the taxonomy" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("bad_work", 0.9))
      Judge.refine(:unknown, "mix test: 3 failures")

      assert [%{state: state, questions: questions}] = ScriptedSystemOne.calls()
      assert state == "mix test: 3 failures"

      assert %{"failure_class" => %{"type" => "choice", "criteria" => criteria}} = questions

      assert MapSet.new(Map.keys(criteria)) ==
               MapSet.new(
                 ~w(provider_error timeout fatal no_changes blocked factory_defect bad_work unknown)
               )
    end

    test "a non-string reason is inspected, the way the matcher sees it" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("factory_defect", 0.9))
      Judge.refine(:unknown, {:provision_failed, :not_found})

      assert [%{state: state}] = ScriptedSystemOne.calls()
      assert state =~ "provision_failed"
    end

    test "a runaway reason is truncated rather than sent whole" do
      {:ok, _} = ScriptedSystemOne.start(ScriptedSystemOne.choice_reply("unknown", 0.5))
      Judge.refine(:unknown, String.duplicate("x", 50_000))

      assert [%{state: state}] = ScriptedSystemOne.calls()
      assert String.length(state) <= 8_000
    end
  end
end
