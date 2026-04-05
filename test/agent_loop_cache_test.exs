defmodule AgentLoopCacheTest do
  use ExUnit.Case, async: false
  import Mox

  alias GiTF.Runtime.AgentLoop
  

  # Mock the LLM Client
  setup :verify_on_exit!

  setup do
    # Ensure mock is used for all tests
    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)

    on_exit(fn ->
      Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Default)
    end)

    :ok
  end

  test "passes cache control for anthropic model" do
    large_prompt = String.duplicate("a", 5000)

    # We expect generate_text to receive messages with cache_control
    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _model, messages, _opts ->
      # Verify system message has cache_control
      system_msg = Enum.find(messages, fn m -> m.role == :system end)
      assert Map.has_key?(system_msg, :cache_control)
      assert system_msg.cache_control == %{"type" => "ephemeral"}

      {:ok, %{text: "ok", usage: %{}}}
    end)

    AgentLoop.run("test", ".",
      model: "anthropic:claude-sonnet-4-6",
      system_prompt: large_prompt,
      max_iterations: 1
    )
  end

  @tag :skip
  test "skips cache control for google model" do
    # Skip: This test requires GOOGLE_API_KEY for GeminiCacheManager.
    # The GeminiCacheManager is called before the mock LLM client,
    # making it impossible to test without a real API key.
    short_prompt = "test prompt"

    GiTF.Runtime.LLMClient.Mock
    |> expect(:generate_text, fn _model, messages, _opts ->
      system_msg = Enum.find(messages, fn m -> m.role == :system end)
      refute Map.has_key?(system_msg, :cache_control)

      {:ok, %{text: "ok", usage: %{}}}
    end)

    AgentLoop.run("test", ".",
      model: "google:gemini-2.0-flash",
      system_prompt: short_prompt,
      max_iterations: 1
    )
  end
end
