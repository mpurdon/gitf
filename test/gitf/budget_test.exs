defmodule GiTF.BudgetTest do
  use ExUnit.Case, async: false

  alias GiTF.{Budget, Costs, Ops}
  alias GiTF.Archive

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "budget-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "budget-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{
        name: "budget-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    {:ok, op} =
      Ops.create(%{title: "budget op", mission_id: mission.id, sector_id: sector.id})

    {:ok, _} = Ops.assign(op.id, ghost.id)

    %{sector: sector, mission: mission, ghost: ghost, op: op}
  end

  # Pins the execution mode so active_provider/0 is deterministic — the
  # global check is scoped to the active provider's spend stream.
  defp with_mode(mode, fun) do
    prev = System.get_env("GITF_EXECUTION_MODE")
    System.put_env("GITF_EXECUTION_MODE", mode)

    try do
      fun.()
    after
      if prev,
        do: System.put_env("GITF_EXECUTION_MODE", prev),
        else: System.delete_env("GITF_EXECUTION_MODE")
    end
  end

  describe "global_check/0 (factory-wide daily cap)" do
    # Dollar caps apply to METERED providers. The cli stream is a flat-rate
    # subscription and is rationed in requests — see BudgetUsageTest.
    test "ok with remaining under the cap", %{ghost: ghost} do
      with_mode("bedrock", fn ->
        {:ok, _} =
          Costs.record(ghost.id, %{
            input_tokens: 1000,
            output_tokens: 500,
            model: "bedrock:anthropic.claude-sonnet-4-6"
          })

        assert {:ok, remaining} = Budget.global_check()
        assert remaining > 0
        assert remaining <= Budget.provider_budget("bedrock")
      end)
    end

    test "blocks once rolling-24h spend exceeds the daily cap", %{ghost: ghost} do
      with_mode("bedrock", fn ->
        # Enormous output spend to clear the $100 default cap in one record.
        {:ok, _} =
          Costs.record(ghost.id, %{
            input_tokens: 0,
            output_tokens: 200_000_000,
            model: "bedrock:anthropic.claude-sonnet-4-6"
          })

        assert {:error, :daily_budget_exceeded, spent} = Budget.global_check()
        assert spent >= Budget.provider_budget("bedrock")
      end)
    end

    test "global_spent sums across all missions' costs", %{ghost: ghost} do
      assert Budget.global_spent() == 0.0

      {:ok, _} =
        Costs.record(ghost.id, %{
          input_tokens: 1_000_000,
          output_tokens: 0,
          model: "claude-sonnet-4-20250514"
        })

      assert Budget.global_spent() > 0.0
    end
  end

  describe "provider-scoped budgets" do
    test "provider_of classifies cost records by model spec" do
      assert Budget.provider_of("bedrock:anthropic.claude-haiku-4-5") == "bedrock"
      assert Budget.provider_of("amazon_bedrock:anthropic.claude-sonnet-4-6") == "bedrock"

      assert Budget.provider_of(
               "arn:aws:bedrock:us-east-1:1:inference-profile/us.anthropic.claude-sonnet-4-6"
             ) == "bedrock"

      assert Budget.provider_of("google:gemini-2.5-flash") == "google"
      # Bare model names only come from the Claude Code CLI booking path
      assert Budget.provider_of("claude-sonnet-4-6") == "cli"
      assert Budget.provider_of(%{model: "google:gemini-2.5-pro"}) == "google"
      assert Budget.provider_of(nil) == "unknown"
    end

    test "spend on one provider does not block another provider's stream", %{ghost: ghost} do
      # Blow past the cap on the bedrock stream…
      {:ok, _} =
        Costs.record(ghost.id, %{
          input_tokens: 0,
          output_tokens: 200_000_000,
          model: "bedrock:anthropic.claude-sonnet-4-6"
        })

      # …bedrock is blocked, but the cli stream still has full headroom.
      with_mode("bedrock", fn ->
        assert {:error, :daily_budget_exceeded, _} = Budget.global_check()
      end)

      # The cli stream is unaffected — and is now measured in requests, so
      # its headroom is the request limit, not a dollar figure.
      with_mode("cli", fn ->
        assert {:ok, remaining} = Budget.global_check()
        assert remaining == Budget.request_limit("cli")
      end)
    end

    test "provider_budget reads [costs.provider_budgets] with daily_budget fallback" do
      prev = GiTF.Config.Provider.get([:costs, :provider_budgets])
      GiTF.Config.Provider.put([:costs, :provider_budgets], %{"cli" => 300.0})

      try do
        assert Budget.provider_budget("cli") == 300.0
        assert Budget.provider_budget("bedrock") == Budget.daily_budget()
      after
        GiTF.Config.Provider.put([:costs, :provider_budgets], prev)
      end
    end

    test "credit pool blocks when cumulative provider spend exhausts pool_usd", %{ghost: ghost} do
      prev = GiTF.Config.Provider.get([:costs, :credit_pools])

      GiTF.Config.Provider.put([:costs, :credit_pools], %{
        "google" => %{"pool_usd" => 5.0, "since" => "2026-01-01"}
      })

      try do
        # Under the pool: passes and reports pool headroom as the binding limit
        assert {:ok, remaining} = Budget.pool_check("google")
        assert remaining == 5.0

        {:ok, _} =
          Costs.record(ghost.id, %{
            input_tokens: 0,
            output_tokens: 0,
            cost_usd: 6.0,
            model: "google:gemini-2.5-pro"
          })

        assert {:error, :credit_pool_exhausted, spent} = Budget.pool_check("google")
        assert spent >= 5.0

        # A different provider's stream is untouched by google's pool
        assert {:ok, _} = Budget.pool_check("cli")
      after
        GiTF.Config.Provider.put([:costs, :credit_pools], prev)
      end
    end

    # A credit pool is pre-paid DOLLARS, which a flat-rate subscription does
    # not have — so pools apply to metered providers only.
    test "global_check surfaces pool exhaustion for the active provider", %{ghost: ghost} do
      prev = GiTF.Config.Provider.get([:costs, :credit_pools])

      GiTF.Config.Provider.put([:costs, :credit_pools], %{
        "bedrock" => %{"pool_usd" => 5.0}
      })

      try do
        {:ok, _} =
          Costs.record(ghost.id, %{
            input_tokens: 0,
            output_tokens: 0,
            cost_usd: 6.0,
            model: "bedrock:anthropic.claude-sonnet-4-6"
          })

        with_mode("bedrock", fn ->
          assert {:error, :credit_pool_exhausted, _} = Budget.global_check()
        end)
      after
        GiTF.Config.Provider.put([:costs, :credit_pools], prev)
      end
    end

    test "config_budget honors [costs.provider_mission_budgets] for the active provider" do
      prev = GiTF.Config.Provider.get([:costs, :provider_mission_budgets])
      GiTF.Config.Provider.put([:costs, :provider_mission_budgets], %{"cli" => 40.0})

      try do
        with_mode("cli", fn -> assert Budget.config_budget() == 40.0 end)
        with_mode("bedrock", fn -> assert Budget.config_budget() != 40.0 end)
      after
        GiTF.Config.Provider.put([:costs, :provider_mission_budgets], prev)
      end
    end
  end

  describe "spent_for/1" do
    test "returns 0 when no costs recorded", %{mission: mission} do
      assert Budget.spent_for(mission.id) == 0.0
    end

    test "sums costs for mission's ghosts", %{mission: mission, ghost: ghost} do
      {:ok, _} =
        Costs.record(ghost.id, %{
          input_tokens: 1000,
          output_tokens: 500,
          model: "claude-sonnet-4-20250514"
        })

      spent = Budget.spent_for(mission.id)
      assert spent > 0.0
    end
  end

  describe "check/1" do
    test "returns ok with remaining when under budget", %{mission: mission} do
      assert {:ok, remaining} = Budget.check(mission.id)
      assert remaining > 0
    end

    test "returns error when budget exceeded", %{mission: mission, ghost: ghost} do
      # Record a huge cost to exceed budget
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})

      assert {:error, :budget_exceeded, spent} = Budget.check(mission.id)
      assert spent >= 999.0
    end
  end

  describe "exceeded?/1" do
    test "returns false when under budget", %{mission: mission} do
      assert Budget.exceeded?(mission.id) == false
    end

    test "returns true when over budget", %{mission: mission, ghost: ghost} do
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 0, output_tokens: 0, cost_usd: 999.0})
      assert Budget.exceeded?(mission.id) == true
    end
  end

  describe "remaining/1" do
    test "returns full budget when nothing spent", %{mission: mission} do
      remaining = Budget.remaining(mission.id)
      assert remaining == Budget.budget_for(mission.id)
    end
  end
end
