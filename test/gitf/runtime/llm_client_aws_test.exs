defmodule GiTF.Runtime.LLMClientAwsTest do
  @moduledoc """
  ReqLLM's Bedrock provider only reads credentials from env vars, so on a box
  that authenticates through its instance role every ReqLLM Bedrock call
  failed — the Cabinet's Discord agent answered every question with "the
  model call failed". The client now hands ReqLLM the same credentials
  `BedrockDirect` already resolves.
  """
  use ExUnit.Case, async: false

  alias GiTF.Runtime.LLMClient.Default, as: Client

  setup do
    keys = ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)
    prev = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    System.put_env("AWS_ACCESS_KEY_ID", "AKIATEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    System.put_env("AWS_SESSION_TOKEN", "token")
    :ok
  end

  test "a Bedrock call carries the resolved credentials" do
    for provider <- ["amazon_bedrock", "bedrock"] do
      opts = Client.inject_aws_credentials(provider, [])
      assert opts[:access_key_id] == "AKIATEST"
      assert opts[:secret_access_key] == "secret"
      assert opts[:session_token] == "token"
      assert is_binary(opts[:region])
    end
  end

  test "credentials the caller passed explicitly win" do
    opts = Client.inject_aws_credentials("amazon_bedrock", access_key_id: "MINE")
    assert opts[:access_key_id] == "MINE"
    refute Keyword.has_key?(opts, :secret_access_key)
  end

  test "other providers are untouched" do
    assert Client.inject_aws_credentials("anthropic", foo: 1) == [foo: 1]
  end
end
