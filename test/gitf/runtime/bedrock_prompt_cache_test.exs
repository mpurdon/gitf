defmodule GiTF.Runtime.BedrockPromptCacheTest do
  # The Converse cachePoint layout is a wire-format contract: without these
  # blocks every agent-loop iteration re-sent the full growing context at
  # full input price (7.5M uncached input tokens on 2026-08-16 alone).
  use ExUnit.Case, async: false

  alias GiTF.Runtime.BedrockDirect

  @anthropic_arn "arn:aws:bedrock:us-east-1:123:inference-profile/us.anthropic.claude-sonnet-4-6"
  @cache_point %{"cachePoint" => %{"type" => "default"}}

  defp messages do
    [
      %{role: :system, content: "You are a ghost."},
      %{role: :user, content: "Do the work."}
    ]
  end

  test "anthropic ARNs get cachePoints on system, tools, and conversation tail" do
    tool = ReqLLM.Tool.new!(name: "probe", description: "d", callback: fn _ -> {:ok, "x"} end)

    body =
      BedrockDirect.build_converse_body(messages(),
        model_id: @anthropic_arn,
        tools: [tool]
      )

    assert List.last(body["system"]) == @cache_point
    assert List.last(body["toolConfig"]["tools"]) == @cache_point
    assert body["messages"] |> List.last() |> Map.fetch!("content") |> List.last() == @cache_point
  end

  test "non-anthropic models get no cachePoints" do
    body =
      BedrockDirect.build_converse_body(messages(),
        model_id: "arn:aws:bedrock:us-east-1:123:inference-profile/amazon.nova-lite-v1"
      )

    refute Enum.any?(body["system"], &(&1 == @cache_point))

    refute body["messages"]
           |> List.last()
           |> Map.fetch!("content")
           |> Enum.any?(&(&1 == @cache_point))
  end

  test "the kill-switch disables cachePoints" do
    Application.put_env(:gitf, :bedrock_prompt_cache, false)
    on_exit(fn -> Application.delete_env(:gitf, :bedrock_prompt_cache) end)

    body = BedrockDirect.build_converse_body(messages(), model_id: @anthropic_arn)

    refute Enum.any?(body["system"], &(&1 == @cache_point))
  end

  test "cost calculation bills cached tokens at cache rates, not double" do
    # 100k effective input of which 90k cache reads: input price applies
    # only to the uncached 10k.
    cost_cached =
      GiTF.Costs.calculate_cost(%{
        model: "bedrock:anthropic.claude-sonnet-4-6",
        input_tokens: 100_000,
        output_tokens: 0,
        cache_read_tokens: 90_000,
        cache_write_tokens: 0
      })

    cost_uncached =
      GiTF.Costs.calculate_cost(%{
        model: "bedrock:anthropic.claude-sonnet-4-6",
        input_tokens: 100_000,
        output_tokens: 0
      })

    assert cost_cached < cost_uncached
  end
end
