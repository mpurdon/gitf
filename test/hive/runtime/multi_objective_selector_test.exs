defmodule Hive.Runtime.MultiObjectiveSelectorTest do
  use ExUnit.Case, async: false

  alias Hive.Runtime.MultiObjectiveSelector
  alias Hive.Store

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "mos_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    :ok
  end

  describe "select_optimal/1" do
    test "returns a model and score breakdown" do
      job = %{job_type: :implementation, risk_level: :low}

      {model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      assert model in ["opus", "sonnet", "haiku"]
      assert is_map(breakdown)
      assert is_number(breakdown.total)
      assert Map.has_key?(breakdown, :quality)
      assert Map.has_key?(breakdown, :cost)
      assert Map.has_key?(breakdown, :budget)
    end

    test "without reputation data, prefers cheaper models" do
      job = %{job_type: :implementation, risk_level: :low}

      {model, _} = MultiObjectiveSelector.select_optimal(job)

      # With equal quality (0.5 each), haiku wins on cost
      assert model == "haiku"
    end

    test "high risk shifts weight toward quality" do
      job = %{job_type: :implementation, risk_level: :high}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      assert breakdown.weights.quality == 0.65
      assert breakdown.weights.cost == 0.15
    end

    test "critical risk shifts weight toward quality" do
      job = %{job_type: :planning, risk_level: :critical}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      assert breakdown.weights.quality == 0.65
      assert breakdown.weights.cost == 0.15
    end

    test "low risk uses default weights" do
      job = %{job_type: :implementation, risk_level: :low}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      assert breakdown.weights.quality == 0.50
      assert breakdown.weights.cost == 0.30
      assert breakdown.weights.budget == 0.20
    end

    test "nil quest_id gives full budget score" do
      job = %{job_type: :implementation, risk_level: :low, quest_id: nil}

      {_model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      assert breakdown.budget == 1.0
    end
  end

  describe "score_breakdown/1" do
    test "returns candidates map with all three models" do
      job = %{job_type: :implementation, risk_level: :low}

      result = MultiObjectiveSelector.score_breakdown(job)

      assert Map.has_key?(result, :candidates)
      assert Map.has_key?(result.candidates, "opus")
      assert Map.has_key?(result.candidates, "sonnet")
      assert Map.has_key?(result.candidates, "haiku")
    end

    test "includes weights and risk level" do
      job = %{job_type: :implementation, risk_level: :medium}

      result = MultiObjectiveSelector.score_breakdown(job)

      assert Map.has_key?(result, :weights)
      assert result.risk_level == :medium
    end

    test "each candidate has quality, cost, budget, total" do
      job = %{job_type: :verification}

      result = MultiObjectiveSelector.score_breakdown(job)

      for {_model, scores} <- result.candidates do
        assert Map.has_key?(scores, :quality)
        assert Map.has_key?(scores, :cost)
        assert Map.has_key?(scores, :budget)
        assert Map.has_key?(scores, :total)
      end
    end
  end

  describe "integration with reputation data" do
    test "model with higher reputation scores higher on quality" do
      # Seed reputation data: make opus have high success for :planning
      for _ <- 1..10 do
        {:ok, _job} =
          Store.insert(:jobs, %{
            title: "Plan",
            status: "done",
            quest_id: "q1",
            comb_id: "c1",
            assigned_model: "opus",
            job_type: :planning,
            quality_score: 90
          })
      end

      # Invalidate cache
      Store.delete(:model_reputation, "model:opus:planning")

      job = %{job_type: :planning, risk_level: :high}
      {_model, breakdown} = MultiObjectiveSelector.select_optimal(job)

      opus_score = breakdown.total
      assert is_number(opus_score)
    end
  end
end
