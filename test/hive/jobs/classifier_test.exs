defmodule Hive.Jobs.ClassifierTest do
  use ExUnit.Case, async: true

  alias Hive.Jobs.Classifier

  describe "classify_type/1" do
    test "classifies planning tasks" do
      assert Classifier.classify_type("plan the authentication system") == :planning
      assert Classifier.classify_type("design the database schema") == :planning
      assert Classifier.classify_type("architect the microservices") == :planning
    end

    test "classifies research tasks" do
      assert Classifier.classify_type("research best practices for caching") == :research
      assert Classifier.classify_type("analyze the current codebase") == :research
      assert Classifier.classify_type("investigate performance issues") == :research
    end

    test "classifies implementation tasks" do
      assert Classifier.classify_type("implement user authentication") == :implementation
      assert Classifier.classify_type("create a new API endpoint") == :implementation
      assert Classifier.classify_type("build the payment system") == :implementation
    end

    test "classifies verification tasks" do
      assert Classifier.classify_type("verify the test coverage") == :verification
      assert Classifier.classify_type("validate the API responses") == :verification
      assert Classifier.classify_type("check the security") == :verification
    end

    test "classifies refactoring tasks" do
      assert Classifier.classify_type("refactor the user module") == :refactoring
      assert Classifier.classify_type("restructure the database layer") == :refactoring
      assert Classifier.classify_type("clean up the authentication code") == :refactoring
    end

    test "classifies bug fixes" do
      assert Classifier.classify_type("fix the login bug") == :simple_fix
      assert Classifier.classify_type("resolve the error in checkout") == :simple_fix
    end

    test "classifies summarization tasks" do
      assert Classifier.classify_type("summarize the changes") == :summarization
      assert Classifier.classify_type("compress the context") == :summarization
    end
  end

  describe "classify_complexity/2" do
    test "classifies planning as always complex" do
      assert Classifier.classify_complexity("simple plan", :planning) == :complex
    end

    test "detects complex tasks" do
      assert Classifier.classify_complexity("complex system integration", :implementation) ==
               :complex

      assert Classifier.classify_complexity("large refactor across multiple modules", :refactoring) ==
               :complex
    end

    test "detects simple tasks" do
      assert Classifier.classify_complexity("simple bug fix", :simple_fix) == :simple
      assert Classifier.classify_complexity("small change to config", :implementation) == :simple
    end

    test "defaults to moderate complexity" do
      assert Classifier.classify_complexity("add a new feature", :implementation) == :moderate
    end
  end

  describe "classify_and_recommend/2" do
    test "recommends opus for planning" do
      result = Classifier.classify_and_recommend("Plan the authentication system")
      assert result.job_type == :planning
      assert result.recommended_model == "claude-opus"
      assert result.complexity == :complex
    end

    test "recommends haiku for research" do
      result = Classifier.classify_and_recommend("Research caching strategies")
      assert result.job_type == :research
      assert result.recommended_model == "claude-haiku"
    end

    test "recommends based on implementation complexity" do
      simple = Classifier.classify_and_recommend("Fix simple typo in config")
      assert simple.recommended_model == "claude-haiku"

      complex = Classifier.classify_and_recommend("Implement complex payment integration")
      assert complex.recommended_model == "claude-opus"

      moderate = Classifier.classify_and_recommend("Add new API endpoint")
      assert moderate.recommended_model == "claude-sonnet"
    end

    test "includes reasoning" do
      result = Classifier.classify_and_recommend("Verify test coverage")
      assert is_binary(result.reason)
      assert String.contains?(result.reason, "verification")
    end
  end
end
