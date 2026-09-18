defmodule GiTF.Cabinet.LLMDepsTest do
  @moduledoc """
  A Cabinet node must be able to make an LLM call.

  Cabinet mode skips the whole `core` subtree, which was right while the
  Cabinet was a pure router. Since M2 its Discord personas call a model in
  process, and `GiTF.Runtime.ProviderCircuit` — which every in-process
  call goes through — needs a supervisor that lived in `core`.

  Found the hard way on 2026-09-18: the first live message after M2
  shipped. The bot started typing, the call exited with `no process`, and
  the operator got silence. These tests are the cheap check that would
  have caught it before the deploy rather than after.
  """
  use ExUnit.Case, async: false

  describe "cabinet-mode supervision covers the LLM path" do
    test "the application declares the provider limiter supervisor in cabinet mode" do
      # Read the source rather than booting a second application: the
      # assertion is about what cabinet mode *declares*, and booting two
      # GiTF applications in one VM is not a thing a test should do.
      source = File.read!("lib/gitf/application.ex")

      [_, cabinet_branch] =
        String.split(source, "CABINET MODE — factory supervision skipped", parts: 2)

      [cabinet_branch, _] = String.split(cabinet_branch, "foundation ++ [core", parts: 2)

      assert cabinet_branch =~ "GiTF.Runtime.ProviderLimiter.Supervisor",
             """
             Cabinet mode does not start ProviderLimiter.Supervisor.

             Every in-process LLM call goes through ProviderCircuit.call/2,
             which calls ProviderLimiter.acquire/1, which starts a
             RateLimiter under that DynamicSupervisor. Without it the call
             exits with :noproc and the Discord personas answer nothing.
             """
    end
  end

  describe "the limiter is reachable when supervised" do
    setup do
      started =
        case DynamicSupervisor.start_link(
               name: GiTF.Runtime.ProviderLimiter.Supervisor,
               strategy: :one_for_one
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      on_exit(fn -> if Process.alive?(started), do: Process.exit(started, :kill) end)
      :ok
    end

    test "acquire/1 succeeds once the supervisor exists" do
      # The exact call that exited on the box. It must return, not exit.
      assert GiTF.Runtime.ProviderLimiter.acquire("bedrock") in [:ok, {:error, :rate_limited}]
    end
  end
end
