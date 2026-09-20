defmodule GiTF.Test.ScriptedSystemOne do
  @moduledoc """
  A scripted `GiTF.SystemOne` for tests.

  Set one reply and every `ask/3` returns it; set an error and every call
  fails. The point of the error mode is to make the fail-closed path as easy
  to assert as the happy one, because that is the path that actually runs on
  a box that is rate-limited or offline.

  Calls are recorded so a test can assert the judge was NOT called — which
  is the whole claim for a regex hit, and unprovable from the return value
  alone.

      config :gitf, :system_one_client, GiTF.Test.ScriptedSystemOne
  """
  @behaviour GiTF.SystemOne

  use Agent

  @doc "Starts (or resets) the scripted client with a canned reply."
  def start(reply) do
    case Process.whereis(__MODULE__) do
      nil ->
        Agent.start_link(fn -> %{reply: reply, calls: []} end, name: __MODULE__)

      pid ->
        :ok = Agent.update(__MODULE__, fn s -> %{s | reply: reply, calls: []} end)
        {:ok, pid}
    end
  end

  @doc """
  A canned Choice reply. `probabilities` defaults to a plausible
  distribution that peaks on `verdict` at `confidence`, so a test only has
  to say what it cares about.
  """
  def choice_reply(verdict, confidence, probabilities \\ nil) do
    {:ok,
     %{
       answers: %{
         "failure_class" => %{
           "type" => "choice",
           "choice" => verdict,
           "confidence" => confidence,
           "probabilities" => probabilities || %{verdict => confidence}
         }
       },
       model: "jev-1.13.0",
       usage: %{"input_tokens" => 210, "output_tokens" => 12}
     }}
  end

  @doc "Every state the client was asked about, oldest first."
  def calls do
    case Process.whereis(__MODULE__) do
      nil -> []
      _ -> Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end
  end

  @doc """
  Stops the Agent so the next test starts clean.

  Tolerates it already being gone. The Agent is linked to the test process,
  so by the time an `on_exit` callback runs — in a different process, after
  the test has exited — it is usually dead already, and `Agent.stop/1` on a
  dead pid exits rather than returning an error.
  """
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def ask(state, questions, _opts) do
    Agent.get_and_update(__MODULE__, fn s ->
      {s.reply, %{s | calls: [%{state: state, questions: questions} | s.calls]}}
    end)
  end
end
