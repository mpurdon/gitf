defmodule GiTF.TestDriver.Scenario do
  @moduledoc """
  DSL for writing GiTF E2E test scenarios.

  `use GiTF.TestDriver.Scenario` sets up ExUnit with harness boot/teardown
  and imports assertion helpers. The `scenario` macro wraps a test body
  with recorder lifecycle management.

  ## Example

      defmodule MyE2ETest do
        use GiTF.TestDriver.Scenario

        scenario "mission completes with two ops" do
          {:ok, env, sector} = Harness.add_sector(env)
          {:ok, mission, [job1, job2]} = Harness.create_quest(env,
            ops: [%{title: "Job 1"}, %{title: "Job 2"}]
          )

          {:ok, _bee1} = Harness.spawn_mock_bee(env, job1.id, sector.id)
          {:ok, _bee2} = Harness.spawn_mock_bee(env, job2.id, sector.id)

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

        # Ensure SectorSupervisor is running (needed for ghost spawning)
        if !Process.whereis(GiTF.SectorSupervisor) do
          DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.SectorSupervisor)
        end

        # E2E mock scripts emit Claude Code stream-json format.
        # Start Config.Provider if not running, then override to use Claude plugin.
        if !Process.whereis(GiTF.Config.Provider) do
          GiTF.Config.Provider.start_link([])
        end

        # Config lives in persistent_term (GiTF.Config.Provider); use its public
        # override API rather than poking ETS directly.
        original_config = GiTF.Config.Provider.all()

        if original_config != %{} do
          GiTF.Config.Provider.put([:plugins, :models, :default], "claude")
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
          # Restore original config.
          try do
            if original_config != %{} do
              GiTF.Config.Provider.replace(original_config)
            end
          rescue
            _ -> :ok
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
