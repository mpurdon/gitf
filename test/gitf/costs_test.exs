defmodule GiTF.CostsTest do
  use GiTF.StoreCase

  alias GiTF.Costs
  alias GiTF.Archive

  setup do
    {:ok, ghost} = Archive.insert(:ghosts, %{name: "cost-test-ghost", status: "starting"})

    %{ghost: ghost}
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
    test "records a cost entry with auto-calculated cost_usd", %{ghost: ghost} do
      attrs = %{
        input_tokens: 500,
        output_tokens: 200,
        model: "google:gemini-2.5-flash"
      }

      assert {:ok, cost} = Costs.record(ghost.id, attrs)
      assert cost.ghost_id == ghost.id
      assert cost.input_tokens == 500
      assert cost.output_tokens == 200
      assert cost.cost_usd > 0
      assert cost.recorded_at != nil
      assert String.starts_with?(cost.id, "cst-")
    end

    test "preserves explicit cost_usd if provided", %{ghost: ghost} do
      attrs = %{
        input_tokens: 500,
        output_tokens: 200,
        cost_usd: 42.0
      }

      assert {:ok, cost} = Costs.record(ghost.id, attrs)
      assert cost.cost_usd == 42.0
    end

    test "preserves explicit recorded_at if provided", %{ghost: ghost} do
      timestamp = ~U[2025-01-15 10:00:00Z]

      attrs = %{
        input_tokens: 100,
        output_tokens: 50,
        recorded_at: timestamp
      }

      assert {:ok, cost} = Costs.record(ghost.id, attrs)
      assert cost.recorded_at == timestamp
    end
  end

  describe "for_bee/1" do
    test "returns costs for a specific ghost", %{ghost: ghost} do
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 100, output_tokens: 50})
      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 200, output_tokens: 100})

      costs = Costs.for_bee(ghost.id)
      assert length(costs) == 2
      assert Enum.all?(costs, &(&1.ghost_id == ghost.id))
    end

    test "returns empty list for unknown ghost" do
      assert [] = Costs.for_bee("ghost-nonexistent")
    end
  end

  describe "for_quest/1" do
    test "returns costs for ghosts working on mission ops", %{ghost: ghost} do
      {:ok, sector} =
        Archive.insert(:sectors, %{
          name: "cost-mission-sector-#{:erlang.unique_integer([:positive])}"
        })

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "cost-mission-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, _job} =
        GiTF.Ops.create(%{
          title: "Quest op",
          mission_id: mission.id,
          sector_id: sector.id,
          ghost_id: ghost.id
        })

      {:ok, _} = Costs.record(ghost.id, %{input_tokens: 300, output_tokens: 150})

      costs = Costs.for_quest(mission.id)
      assert length(costs) >= 1
    end
  end

  describe "total/1" do
    test "sums cost_usd from a list of costs", %{ghost: ghost} do
      {:ok, c1} = Costs.record(ghost.id, %{input_tokens: 1_000_000, output_tokens: 0})
      {:ok, c2} = Costs.record(ghost.id, %{input_tokens: 1_000_000, output_tokens: 0})

      total = Costs.total([c1, c2])
      # 2 * $0.15/MTok (gemini-2.5-flash default) = $0.30
      assert_in_delta total, 0.30, 0.001
    end

    test "returns zero for empty list" do
      assert Costs.total([]) == 0.0
    end
  end

  describe "summary/0" do
    test "returns aggregate cost data with by_category", %{ghost: ghost} do
      {:ok, _} =
        Costs.record(ghost.id, %{
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
    test "queen ghost_id maps to orchestration" do
      {:ok, cost} = Costs.record("major", %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "orchestration"
    end

    test "explicit category overrides auto-derivation" do
      {:ok, cost} =
        Costs.record("major", %{input_tokens: 100, output_tokens: 50, category: "planning"})

      assert cost.category == "planning"
    end

    test "unknown ghost falls back to unknown" do
      {:ok, cost} =
        Costs.record("ghost-nonexistent-#{:erlang.unique_integer([:positive])}", %{
          input_tokens: 100,
          output_tokens: 50
        })

      assert cost.category == "unknown"
    end

    test "phase op research maps to planning", %{ghost: ghost} do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "cat-sector-#{:erlang.unique_integer([:positive])}"})

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "cat-mission-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Research task",
          mission_id: mission.id,
          sector_id: sector.id,
          ghost_id: ghost.id,
          phase_job: true,
          phase: "research"
        })

      # Update ghost with op_id
      Archive.put(:ghosts, Map.put(ghost, :op_id, op.id))

      {:ok, cost} = Costs.record(ghost.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "planning"
    end

    test "phase op validation maps to verification", %{ghost: ghost} do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "cat-sector-#{:erlang.unique_integer([:positive])}"})

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "cat-mission-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Validation task",
          mission_id: mission.id,
          sector_id: sector.id,
          ghost_id: ghost.id,
          phase_job: true,
          phase: "validation"
        })

      Archive.put(:ghosts, Map.put(ghost, :op_id, op.id))

      {:ok, cost} = Costs.record(ghost.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "verification"
    end

    test "non-phase op maps to implementation", %{ghost: ghost} do
      {:ok, sector} =
        Archive.insert(:sectors, %{name: "cat-sector-#{:erlang.unique_integer([:positive])}"})

      {:ok, mission} =
        Archive.insert(:missions, %{
          name: "cat-mission-#{:erlang.unique_integer([:positive])}",
          status: "pending"
        })

      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Implementation task",
          mission_id: mission.id,
          sector_id: sector.id,
          ghost_id: ghost.id,
          phase_job: false
        })

      Archive.put(:ghosts, Map.put(ghost, :op_id, op.id))

      {:ok, cost} = Costs.record(ghost.id, %{input_tokens: 100, output_tokens: 50})
      assert cost.category == "implementation"
    end

    test "summary includes by_category grouping" do
      {:ok, _} =
        Costs.record("major", %{input_tokens: 500, output_tokens: 250})

      summary = Costs.summary()
      assert Map.has_key?(summary.by_category, "orchestration")
      assert summary.by_category["orchestration"].input_tokens == 500
    end
  end
end
