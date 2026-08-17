defmodule GiTF.Runtime.CLIClientTest do
  # Provider invariant: in :cli execution mode, in-process LLM calls route
  # through the claude CLI backend — never silently to a metered API.
  use ExUnit.Case, async: false

  alias GiTF.Runtime.{CLIClient, LLMClient}

  defp with_mode(mode, fun) do
    prev = System.get_env("GITF_EXECUTION_MODE")
    System.put_env("GITF_EXECUTION_MODE", mode)

    try do
      fun.()
    after
      if prev,
        do: System.put_env("GITF_EXECUTION_MODE", prev),
        else: System.delete_env("GITF_EXECUTION_MODE")
    end
  end

  describe "LLMClient.impl/0 routing" do
    test "cli mode routes to CLIClient, api mode to Default (absent explicit config)" do
      prev = Application.get_env(:gitf, :llm_client)
      Application.delete_env(:gitf, :llm_client)

      try do
        with_mode("cli", fn -> assert LLMClient.impl() == CLIClient end)
        with_mode("api", fn -> assert LLMClient.impl() == LLMClient.Default end)
        with_mode("bedrock", fn -> assert LLMClient.impl() == LLMClient.Default end)
      after
        if prev, do: Application.put_env(:gitf, :llm_client, prev)
      end
    end

    test "explicit config (the test Mock) always wins" do
      # The suite configures the Mock; impl must honor it in any mode.
      assert Application.get_env(:gitf, :llm_client) == nil or
               LLMClient.impl() == Application.get_env(:gitf, :llm_client)
    end
  end

  describe "flatten_messages/1" do
    test "bare string passes through with no system prompt" do
      assert CLIClient.flatten_messages("hello") == {"", "hello"}
    end

    test "role maps split system from conversation" do
      msgs = [
        %{"role" => "system", "content" => "be terse"},
        %{"role" => "user", "content" => "hi"},
        %{role: :assistant, content: "hello"},
        %{role: :user, content: "continue"}
      ]

      {system, prompt} = CLIClient.flatten_messages(msgs)
      assert system == "be terse"
      assert prompt =~ "hi"
      assert prompt =~ "Assistant: hello"
      assert prompt =~ "continue"
    end

    test "content block lists are joined" do
      msgs = [%{role: :user, content: [%{text: "a"}, %{"text" => "b"}]}]
      assert {"", "ab"} = CLIClient.flatten_messages(msgs)
    end
  end

  describe "build_response/2" do
    test "extracts final text and real usage from a stream-json transcript" do
      raw =
        Enum.join(
          [
            ~s({"type":"system","subtype":"init","model":"claude-sonnet-5"}),
            ~s({"type":"assistant","message":{"content":[{"type":"text","text":"draft"}]}}),
            ~s({"type":"result","subtype":"success","result":"final answer","usage":{"input_tokens":120,"output_tokens":30},"cost_usd":0.002,"model":"claude-sonnet-5"})
          ],
          "\n"
        )

      resp = CLIClient.build_response("sonnet", raw)

      assert %ReqLLM.Response{} = resp
      assert [%{text: "final answer"}] = resp.message.content
      assert resp.usage.input_tokens == 120
      assert resp.usage.output_tokens == 30
    end
  end
end
