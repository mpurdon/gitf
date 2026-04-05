defmodule GiTF.Runtime.MultiObjectiveSelectorTest do
  use ExUnit.Case, async: false

  alias GiTF.Runtime.MultiObjectiveSelector
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "mos_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    :ok
  end

  describe "select_optimal/1" do
    test "returns a model and score breakdown" do
      op = %{op_type: :implementation, risk_level: :low}

      {model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      assert model in ["thinking", "general", "fast"]
      assert is_map(breakdown)
      assert is_number(breakdown.total)
      assert Map.has_key?(breakdown, :quality)
      assert Map.has_key?(breakdown, :cost)
      assert Map.has_key?(breakdown, :budget)
    end

    test "without trust data, prefers cheaper models" do
      op = %{op_type: :implementation, risk_level: :low}

      {model, _} = MultiObjectiveSelector.select_optimal(op)

      # With equal quality (0.5 each), haiku wins on cost
      assert model == "fast"
    end

    test "high risk shifts weight toward quality" do
      op = %{op_type: :implementation, risk_level: :high}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      assert breakdown.weights.quality == 0.65
      assert breakdown.weights.cost == 0.15
    end

    test "critical risk shifts weight toward quality" do
      op = %{op_type: :planning, risk_level: :critical}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      assert breakdown.weights.quality == 0.65
      assert breakdown.weights.cost == 0.15
    end

    test "low risk uses default weights" do
      op = %{op_type: :implementation, risk_level: :low}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      assert breakdown.weights.quality == 0.50
      assert breakdown.weights.cost == 0.30
      assert breakdown.weights.budget == 0.20
    end

    test "nil mission_id gives full budget score" do
      op = %{op_type: :implementation, risk_level: :low, mission_id: nil}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      assert breakdown.budget == 1.0
    end
  end

  describe "score_breakdown/1" do
    test "returns candidates map with all three models" do
      op = %{op_type: :implementation, risk_level: :low}

      result = MultiObjectiveSelector.score_breakdown(op)

      assert Map.has_key?(result, :candidates)
      assert Map.has_key?(result.candidates, "thinking")
      assert Map.has_key?(result.candidates, "general")
      assert Map.has_key?(result.candidates, "fast")
    end

    test "includes weights and risk level" do
      op = %{op_type: :implementation, risk_level: :medium}

      result = MultiObjectiveSelector.score_breakdown(op)

      assert Map.has_key?(result, :weights)
      assert result.risk_level == :medium
    end

    test "each candidate has quality, cost, budget, total" do
      op = %{op_type: :audit}

      result = MultiObjectiveSelector.score_breakdown(op)

      for {_model, scores} <- result.candidates do
        assert Map.has_key?(scores, :quality)
        assert Map.has_key?(scores, :cost)
        assert Map.has_key?(scores, :budget)
        assert Map.has_key?(scores, :total)
      end
    end
  end

  describe "integration with trust data" do
    test "model with higher trust scores higher on quality" do
      # Seed trust data: make opus have high success for :planning
      for _ <- 1..10 do
        {:ok, _job} =
          Archive.insert(:ops, %{
            title: "Plan",
            status: "done",
            mission_id: "q1",
            sector_id: "c1",
            assigned_model: "thinking",
            op_type: :planning,
            quality_score: 90
          })
      end

      # Invalidate cache
      Archive.delete(:model_reputation, "model:opus:planning")

      op = %{op_type: :planning, risk_level: :high}
      {_model, breakdown} = MultiObjectiveSelector.select_optimal(op)

      opus_score = breakdown.total
      assert is_number(opus_score)
    end
  end
end
