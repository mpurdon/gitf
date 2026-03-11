defmodule GiTF.TestDriver.Scenario do
  @moduledoc """
  DSL for writing GiTF E2E test scenarios.

  `use GiTF.TestDriver.Scenario` sets up ExUnit with harness boot/teardown
  and imports assertion helpers. The `scenario` macro wraps a test body
  with recorder lifecycle management.

  ## Example

      defmodule MyE2ETest do
        use GiTF.TestDriver.Scenario

        scenario "quest completes with two jobs" do
          {:ok, env, comb} = Harness.add_comb(env)
          {:ok, quest, [job1, job2]} = Harness.create_quest(env,
            jobs: [%{title: "Job 1"}, %{title: "Job 2"}]
          )

          {:ok, _bee1} = Harness.spawn_mock_bee(env, job1.id, comb.id)
          {:ok, _bee2} = Harness.spawn_mock_bee(env, job2.id, comb.id)

          await {:job_done, job1.id}
          await {:job_done, job2.id}
          assert_waggle subject: "job_complete", from: _bee1.id
        end
      end

  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      alias GiTF.TestDriver.Harness
      alias GiTF.TestDriver.Recorder
      alias GiTF.TestDriver.MockClaude

      import GiTF.TestDriver.Assertions
      import GiTF.TestDriver.Scenario, only: [scenario: 2]

      @moduletag :e2e

      setup do
        GiTF.Test.StoreHelper.ensure_infrastructure()

        # Ensure CombSupervisor is running (needed for ghost spawning)
        unless Process.whereis(GiTF.CombSupervisor) do
          DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.CombSupervisor)
        end

        # E2E mock scripts emit Claude Code stream-json format.
        # Start Config.Provider if not running, then override to use Claude plugin.
        unless Process.whereis(GiTF.Config.Provider) do
          GiTF.Config.Provider.start_link([])
        end

        original_config =
          try do
            [{:config, c}] = :ets.lookup(:gitf_config, :config)
            c
          rescue
            _ -> nil
          end

        if original_config do
          updated = put_in(original_config, [:plugins, :models, :default], "claude")
          :ets.insert(:gitf_config, {:config, updated})
        end

        # Hide real Claude from the Validator's find_executable lookup.
        # Bee Workers use claude_executable directly (mock scripts), so
        # they're unaffected. This prevents the Validator from spawning
        # real Claude for diff assessment (which takes 60s to timeout).
        # We filter PATH entries to remove directories containing the
        # claude binary while keeping git, sh, etc. available.
        original_path = System.get_env("PATH")

        filtered_path =
          original_path
          |> String.split(":")
          |> Enum.reject(fn dir ->
            File.exists?(Path.join(dir, "claude"))
          end)
          |> Enum.join(":")

        System.put_env("PATH", filtered_path)

        env = Harness.boot()
        {:ok, _} = Recorder.start_link()

        on_exit(fn ->
          Recorder.stop()
          Harness.teardown(env)
          System.put_env("PATH", original_path)
          # Restore original config (may fail if Config.Provider was stopped)
          try do
            if original_config do
              :ets.insert(:gitf_config, {:config, original_config})
            end
          rescue
            ArgumentError -> :ok
          end
        end)

        %{env: env}
      end
    end
  end

  @doc """
  Defines an E2E scenario.

  Wraps the test body with the harness environment from the setup context.
  The `env` variable is automatically available in the scenario body.
  """
  defmacro scenario(name, do: block) do
    quote do
      @tag :e2e
      test unquote(name), %{env: var!(env)} do
        _ = var!(env)
        unquote(block)
      end
    end
  end
end
