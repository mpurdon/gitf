defmodule GiTF.Runtime.ModelResolverTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.ModelResolver

  describe "resolve/1" do
    test "resolves tier names to provider-qualified specs" do
      assert ModelResolver.resolve("opus") == "google:gemini-2.5-pro"
      assert ModelResolver.resolve("sonnet") == "google:gemini-2.5-flash"
      assert ModelResolver.resolve("haiku") == "google:gemini-2.5-flash"
      assert ModelResolver.resolve("fast") == "google:gemini-2.5-flash"
    end

    test "resolves legacy names" do
      assert ModelResolver.resolve("claude-opus") == "anthropic:claude-opus-4-6"
      assert ModelResolver.resolve("claude-sonnet") == "anthropic:claude-sonnet-4-6"
      assert ModelResolver.resolve("claude-haiku") == "anthropic:claude-haiku-4-5"
    end

    test "passes through provider-qualified names unchanged" do
      assert ModelResolver.resolve("anthropic:claude-opus-4-6") == "anthropic:claude-opus-4-6"
      assert ModelResolver.resolve("google:gemini-2.5-pro") == "google:gemini-2.5-pro"
      assert ModelResolver.resolve("openai:gpt-4o") == "openai:gpt-4o"
    end

    test "passes through unknown names unchanged" do
      assert ModelResolver.resolve("some-unknown-model") == "some-unknown-model"
    end
  end

  describe "provider/1" do
    test "extracts provider from qualified name" do
      assert ModelResolver.provider("anthropic:claude-opus-4-6") == "anthropic"
      assert ModelResolver.provider("google:gemini-2.5-flash") == "google"
      assert ModelResolver.provider("openai:gpt-4o") == "openai"
    end

    test "resolves tier then extracts provider" do
      assert ModelResolver.provider("opus") == "google"
      assert ModelResolver.provider("fast") == "google"
    end

    test "defaults to google for unqualified unknown names" do
      assert ModelResolver.provider("unknown") == "google"
    end
  end

  describe "model_id/1" do
    test "extracts model id from qualified name" do
      assert ModelResolver.model_id("anthropic:claude-opus-4-6") == "claude-opus-4-6"
      assert ModelResolver.model_id("google:gemini-2.5-flash") == "gemini-2.5-flash"
    end

    test "resolves tier then extracts model id" do
      assert ModelResolver.model_id("sonnet") == "gemini-2.5-flash"
      assert ModelResolver.model_id("fast") == "gemini-2.5-flash"
    end
  end

  describe "execution_mode/0" do
    test "returns :api or :cli" do
      mode = ModelResolver.execution_mode()
      assert mode in [:api, :cli]
    end
  end

  describe "api_mode?/0" do
    test "returns a boolean" do
      assert is_boolean(ModelResolver.api_mode?())
    end
  end

  describe "configured_models/0" do
    test "returns a map with standard tier keys" do
      models = ModelResolver.configured_models()
      assert is_map(models)
      assert Map.has_key?(models, "opus")
      assert Map.has_key?(models, "sonnet")
      assert Map.has_key?(models, "haiku")
      assert Map.has_key?(models, "fast")
    end
  end
end
