defmodule Hive.CostsTest do
  use ExUnit.Case, async: false

  alias Hive.Costs
  alias Hive.Store

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hive_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Hive.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, bee} = Store.insert(:bees, %{name: "cost-test-bee", status: "starting"})

    %{bee: bee}
  end

  describe "calculate_cost/1" do
    test "calculates cost with default model pricing (gemini-2.5-flash)" do
      attrs = %{
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        cache_read_tokens: 0,
        cache_write_tokens: 0
      }

      # gemini-2.5-flash: $0.15/MTok input + $0.60/MTok output = $0.75
      cost = Costs.calculate_cost(attrs)
      assert_in_delta cost, 0.75, 0.001
    end

    test "calculates cost with gemini-2.5-pro pricing" do
      attrs = %{
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        model: "google:gemini-2.5-pro"
      }

      # gemini-2.5-pro: $1.25/MTok input + $10.0/MTok output = $11.25
      cost = Costs.calculate_cost(attrs)
      assert_in_delta cost, 11.25, 0.001
    end

    test "includes cache token costs" do
      attrs = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 1_000_000,
        cache_write_tokens: 1_000_000,
        model: "anthropic:claude-sonnet-4-6"
      }

      # claude-sonnet cache: $0.30/MTok read + $3.75/MTok write = $4.05
      cost = Costs.calculate_cost(attrs)
      assert_in_delta cost, 4.05, 0.001
    end

    test "returns zero for zero tokens" do
      attrs = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cache_write_tokens: 0
      }

      assert Costs.calculate_cost(attrs) == 0.0
    end

    test "defaults to gemini-2.5-flash pricing for unknown model" do
      attrs = %{
        input_tokens: 1_000_000,
        output_tokens: 0,
        model: "unknown-model"
      }

      # defaults to gemini-2.5-flash: $0.15/MTok input
      cost = Costs.calculate_cost(attrs)
      assert_in_delta cost, 0.15, 0.001
    end
  end

  describe "record/2" do
    test "records a cost entry with auto-calculated cost_usd", %{bee: bee} do
      attrs = %{
        input_tokens: 500,
        output_tokens: 200,
        model: "google:gemini-2.5-flash"
      }

      assert {:ok, cost} = Costs.record(bee.id, attrs)
      assert cost.bee_id == bee.id
      assert cost.input_tokens == 500
      assert cost.output_tokens == 200
      assert cost.cost_usd > 0
      assert cost.recorded_at != nil
      assert String.starts_with?(cost.id, "cst-")
    end

    test "preserves explicit cost_usd if provided", %{bee: bee} do
      attrs = %{
        input_tokens: 500,
        output_tokens: 200,
        cost_usd: 42.0
      }

      assert {:ok, cost} = Costs.record(bee.id, attrs)
      assert cost.cost_usd == 42.0
    end

    test "preserves explicit recorded_at if provided", %{bee: bee} do
      timestamp = ~U[2025-01-15 10:00:00Z]

      attrs = %{
        input_tokens: 100,
        output_tokens: 50,
        recorded_at: timestamp
      }

      assert {:ok, cost} = Costs.record(bee.id, attrs)
      assert cost.recorded_at == timestamp
    end
  end

  describe "for_bee/1" do
    test "returns costs for a specific bee", %{bee: bee} do
      {:ok, _} = Costs.record(bee.id, %{input_tokens: 100, output_tokens: 50})
      {:ok, _} = Costs.record(bee.id, %{input_tokens: 200, output_tokens: 100})

      costs = Costs.for_bee(bee.id)
      assert length(costs) == 2
      assert Enum.all?(costs, &(&1.bee_id == bee.id))
    end

    test "returns empty list for unknown bee" do
      assert [] = Costs.for_bee("bee-nonexistent")
    end
  end

  describe "for_quest/1" do
    test "returns costs for bees working on quest jobs", %{bee: bee} do
      {:ok, comb} =
        Store.insert(:combs, %{name: "cost-quest-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "cost-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, _job} =
        Hive.Jobs.create(%{
          title: "Quest job",
          quest_id: quest.id,
          comb_id: comb.id,
          bee_id: bee.id
        })

      {:ok, _} = Costs.record(bee.id, %{input_tokens: 300, output_tokens: 150})

      costs = Costs.for_quest(quest.id)
      assert length(costs) >= 1
    end
  end

  describe "total/1" do
    test "sums cost_usd from a list of costs", %{bee: bee} do
      {:ok, c1} = Costs.record(bee.id, %{input_tokens: 1_000_000, output_tokens: 0})
      {:ok, c2} = Costs.record(bee.id, %{input_tokens: 1_000_000, output_tokens: 0})

      total = Costs.total([c1, c2])
      # 2 * $0.15/MTok (gemini-2.5-flash default) = $0.30
      assert_in_delta total, 0.30, 0.001
    end

    test "returns zero for empty list" do
      assert Costs.total([]) == 0.0
    end
  end

  describe "summary/0" do
    test "returns aggregate cost data with by_category", %{bee: bee} do
      {:ok, _} =
        Costs.record(bee.id, %{
          input_tokens: 1000,
          output_tokens: 500,
          model: "google:gemini-2.5-flash"
        })

      summary = Costs.summary()
      assert summary.total_cost > 0
      assert summary.total_input_tokens >= 1000
      assert summary.total_output_tokens >= 500
      assert is_map(summary.by_model)
      assert is_map(summary.by_bee)
      assert is_map(summary.by_category)
    end

    test "returns zeroes when no costs recorded" do
      summary = Costs.summary()
      assert is_float(summary.total_cost)
      assert is_integer(summary.total_input_tokens)
      assert is_integer(summary.total_output_tokens)
    end
  end

  describe "category derivation" do
    test "queen bee_id maps to orchestration" do
      {:ok, cost} = Costs.record("queen", %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "orchestration"
    end

    test "explicit category overrides auto-derivation" do
      {:ok, cost} =
        Costs.record("queen", %{input_tokens: 100, output_tokens: 50, category: "planning"})

      assert cost.category == "planning"
    end

    test "unknown bee falls back to unknown" do
      {:ok, cost} =
        Costs.record("bee-nonexistent-#{:erlang.unique_integer([:positive])}", %{
          input_tokens: 100,
          output_tokens: 50
        })

      assert cost.category == "unknown"
    end

    test "phase job research maps to planning", %{bee: bee} do
      {:ok, comb} =
        Store.insert(:combs, %{name: "cat-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "cat-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Research task",
          quest_id: quest.id,
          comb_id: comb.id,
          bee_id: bee.id,
          phase_job: true,
          phase: "research"
        })

      # Update bee with job_id
      Store.put(:bees, Map.put(bee, :job_id, job.id))

      {:ok, cost} = Costs.record(bee.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "planning"
    end

    test "phase job validation maps to verification", %{bee: bee} do
      {:ok, comb} =
        Store.insert(:combs, %{name: "cat-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "cat-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Validation task",
          quest_id: quest.id,
          comb_id: comb.id,
          bee_id: bee.id,
          phase_job: true,
          phase: "validation"
        })

      Store.put(:bees, Map.put(bee, :job_id, job.id))

      {:ok, cost} = Costs.record(bee.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "verification"
    end

    test "non-phase job maps to implementation", %{bee: bee} do
      {:ok, comb} =
        Store.insert(:combs, %{name: "cat-comb-#{:erlang.unique_integer([:positive])}"})

      {:ok, quest} =
        Store.insert(:quests, %{
          name: "cat-quest-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Implementation task",
          quest_id: quest.id,
          comb_id: comb.id,
          bee_id: bee.id,
          phase_job: false
        })

      Store.put(:bees, Map.put(bee, :job_id, job.id))

      {:ok, cost} = Costs.record(bee.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "implementation"
    end

    test "summary includes by_category grouping" do
      {:ok, _} =
        Costs.record("queen", %{input_tokens: 500, output_tokens: 250})

      summary = Costs.summary()
      assert Map.has_key?(summary.by_category, "orchestration")
      assert summary.by_category["orchestration"].input_tokens == 500
    end
  end
end
