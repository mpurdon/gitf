defmodule GiTF.Runtime.ModelSelectorTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.ModelSelector

  describe "select_model_for_job/2" do
    test "selects opus for planning tasks" do
      assert ModelSelector.select_model_for_job(:planning, :simple) == "opus"
      assert ModelSelector.select_model_for_job(:planning, :complex) == "opus"
    end

    test "selects haiku for research tasks" do
      assert ModelSelector.select_model_for_job(:research, :simple) == "haiku"
      assert ModelSelector.select_model_for_job(:research, :complex) == "haiku"
    end

    test "selects haiku for verification tasks" do
      assert ModelSelector.select_model_for_job(:audit, :simple) == "haiku"
    end

    test "selects haiku for summarization tasks" do
      assert ModelSelector.select_model_for_job(:summarization, :simple) == "haiku"
    end

    test "selects model based on implementation complexity" do
      assert ModelSelector.select_model_for_job(:implementation, :simple) == "haiku"
      assert ModelSelector.select_model_for_job(:implementation, :moderate) == "sonnet"
      assert ModelSelector.select_model_for_job(:implementation, :complex) == "opus"
    end

    test "selects model based on refactoring complexity" do
      assert ModelSelector.select_model_for_job(:refactoring, :moderate) == "sonnet"
      assert ModelSelector.select_model_for_job(:refactoring, :complex) == "opus"
    end
  end

  describe "get_model_info/1" do
    test "returns info for known models" do
      assert {:ok, info} = ModelSelector.get_model_info("opus")
      assert info.cost_tier == :high
      assert :planning in info.capabilities

      assert {:ok, info} = ModelSelector.get_model_info("sonnet")
      assert info.cost_tier == :medium

      assert {:ok, info} = ModelSelector.get_model_info("haiku")
      assert info.cost_tier == :low
    end

    test "returns error for unknown models" do
      assert {:error, :not_found} = ModelSelector.get_model_info("unknown-model")
    end
  end

  describe "list_models/0" do
    test "returns all available models" do
      models = ModelSelector.list_models()
      assert "opus" in models
      assert "sonnet" in models
      assert "haiku" in models
    end
  end

  describe "models_with_capability/1" do
    test "returns models with planning capability" do
      models = ModelSelector.models_with_capability(:planning)
      assert "opus" in models
      refute "haiku" in models
    end

    test "returns models with research capability" do
      models = ModelSelector.models_with_capability(:research)
      assert "haiku" in models
    end
  end

  describe "cheapest_model_for_job/1" do
    test "returns cheapest model for research" do
      assert ModelSelector.cheapest_model_for_job(:research) == "haiku"
    end

    test "returns cheapest model for implementation" do
      # Sonnet is the cheapest that can do general implementation
      assert ModelSelector.cheapest_model_for_job(:implementation) == "sonnet"
    end
  end
end
