defmodule GiTF.Runtime.ModelSelectorTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.ModelSelector

  describe "select_model_for_job/2" do
    test "selects thinking for planning tasks" do
      assert ModelSelector.select_model_for_job(:planning, :simple) == "thinking"
      assert ModelSelector.select_model_for_job(:planning, :complex) == "thinking"
    end

    test "selects fast for research tasks" do
      assert ModelSelector.select_model_for_job(:research, :simple) == "fast"
      assert ModelSelector.select_model_for_job(:research, :complex) == "fast"
    end

    test "selects fast for verification tasks" do
      assert ModelSelector.select_model_for_job(:audit, :simple) == "fast"
    end

    test "selects fast for summarization tasks" do
      assert ModelSelector.select_model_for_job(:summarization, :simple) == "fast"
    end

    test "selects model based on implementation complexity" do
      assert ModelSelector.select_model_for_job(:implementation, :simple) == "general"
      assert ModelSelector.select_model_for_job(:implementation, :moderate) == "general"
      assert ModelSelector.select_model_for_job(:implementation, :complex) == "thinking"
    end

    test "selects model based on refactoring complexity" do
      assert ModelSelector.select_model_for_job(:refactoring, :moderate) == "general"
      assert ModelSelector.select_model_for_job(:refactoring, :complex) == "thinking"
    end
  end

  describe "get_model_info/1" do
    test "returns info for known models" do
      assert {:ok, info} = ModelSelector.get_model_info("thinking")
      assert info.cost_tier == :high
      assert :planning in info.capabilities

      assert {:ok, info} = ModelSelector.get_model_info("general")
      assert info.cost_tier == :medium

      assert {:ok, info} = ModelSelector.get_model_info("fast")
      assert info.cost_tier == :low
    end

    test "returns error for unknown models" do
      assert {:error, :not_found} = ModelSelector.get_model_info("unknown-model")
    end
  end

  describe "list_models/0" do
    test "returns all available models" do
      models = ModelSelector.list_models()
      assert "thinking" in models
      assert "general" in models
      assert "fast" in models
    end
  end

  describe "models_with_capability/1" do
    test "returns models with planning capability" do
      models = ModelSelector.models_with_capability(:planning)
      assert "thinking" in models
      refute "fast" in models
    end

    test "returns models with research capability" do
      models = ModelSelector.models_with_capability(:research)
      assert "fast" in models
    end
  end

  describe "cheapest_model_for_job/1" do
    test "returns cheapest model for research" do
      assert ModelSelector.cheapest_model_for_job(:research) == "fast"
    end

    test "returns cheapest model for implementation" do
      assert ModelSelector.cheapest_model_for_job(:implementation) == "general"
    end
  end
end
