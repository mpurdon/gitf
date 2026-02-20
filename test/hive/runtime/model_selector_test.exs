defmodule Hive.Runtime.ModelSelectorTest do
  use ExUnit.Case, async: true

  alias Hive.Runtime.ModelSelector

  describe "select_model_for_job/2" do
    test "selects opus for planning tasks" do
      assert ModelSelector.select_model_for_job(:planning, :simple) == "claude-opus"
      assert ModelSelector.select_model_for_job(:planning, :complex) == "claude-opus"
    end

    test "selects haiku for research tasks" do
      assert ModelSelector.select_model_for_job(:research, :simple) == "claude-haiku"
      assert ModelSelector.select_model_for_job(:research, :complex) == "claude-haiku"
    end

    test "selects haiku for verification tasks" do
      assert ModelSelector.select_model_for_job(:verification, :simple) == "claude-haiku"
    end

    test "selects haiku for summarization tasks" do
      assert ModelSelector.select_model_for_job(:summarization, :simple) == "claude-haiku"
    end

    test "selects model based on implementation complexity" do
      assert ModelSelector.select_model_for_job(:implementation, :simple) == "claude-haiku"
      assert ModelSelector.select_model_for_job(:implementation, :moderate) == "claude-sonnet"
      assert ModelSelector.select_model_for_job(:implementation, :complex) == "claude-opus"
    end

    test "selects model based on refactoring complexity" do
      assert ModelSelector.select_model_for_job(:refactoring, :moderate) == "claude-sonnet"
      assert ModelSelector.select_model_for_job(:refactoring, :complex) == "claude-opus"
    end
  end

  describe "get_model_info/1" do
    test "returns info for known models" do
      assert {:ok, info} = ModelSelector.get_model_info("claude-opus")
      assert info.cost_tier == :high
      assert :planning in info.capabilities

      assert {:ok, info} = ModelSelector.get_model_info("claude-sonnet")
      assert info.cost_tier == :medium

      assert {:ok, info} = ModelSelector.get_model_info("claude-haiku")
      assert info.cost_tier == :low
    end

    test "returns error for unknown models" do
      assert {:error, :not_found} = ModelSelector.get_model_info("unknown-model")
    end
  end

  describe "list_models/0" do
    test "returns all available models" do
      models = ModelSelector.list_models()
      assert "claude-opus" in models
      assert "claude-sonnet" in models
      assert "claude-haiku" in models
    end
  end

  describe "models_with_capability/1" do
    test "returns models with planning capability" do
      models = ModelSelector.models_with_capability(:planning)
      assert "claude-opus" in models
      refute "claude-haiku" in models
    end

    test "returns models with research capability" do
      models = ModelSelector.models_with_capability(:research)
      assert "claude-haiku" in models
    end
  end

  describe "cheapest_model_for_job/1" do
    test "returns cheapest model for research" do
      assert ModelSelector.cheapest_model_for_job(:research) == "claude-haiku"
    end

    test "returns cheapest model for implementation" do
      # Sonnet is the cheapest that can do general implementation
      assert ModelSelector.cheapest_model_for_job(:implementation) == "claude-sonnet"
    end
  end
end
