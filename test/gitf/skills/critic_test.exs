defmodule GiTF.Skills.CriticTest do
  use ExUnit.Case, async: false

  alias GiTF.Skills.Critic

  defmodule LLMStub do
    @behaviour GiTF.Runtime.LLMClient

    def set_response(text) do
      :persistent_term.put({__MODULE__, :response}, text)
    end

    @impl true
    def generate_text(_model, _messages, _opts) do
      text = :persistent_term.get({__MODULE__, :response}, "")
      {:ok, %{message: %{content: [%{text: text}]}}}
    end

    @impl true
    def stream_text(_model, _messages, _opts), do: {:error, :not_implemented}
  end

  setup do
    prev = Application.get_env(:gitf, :llm_client)
    Application.put_env(:gitf, :llm_client, LLMStub)

    on_exit(fn ->
      :persistent_term.erase({LLMStub, :response})

      if prev,
        do: Application.put_env(:gitf, :llm_client, prev),
        else: Application.delete_env(:gitf, :llm_client)
    end)

    %{
      proposal: %{
        name: "test-skill",
        description: "a proposed rule",
        body: "---\nname: test-skill\n---\nbody",
        scope: :global,
        source: :auto_drafted
      }
    }
  end

  describe "review/2" do
    test "parses approve verdict", %{proposal: p} do
      LLMStub.set_response("VERDICT: approve | REASON: Good generalizable rule")

      assert {:ok, :approve, reason} = Critic.review(p, [])
      assert reason =~ "generalizable"
    end

    test "parses reject verdict", %{proposal: p} do
      LLMStub.set_response("VERDICT: reject | REASON: Too vague to act on")

      assert {:ok, :reject, reason} = Critic.review(p, [])
      assert reason =~ "vague"
    end

    test "parses needs_revision verdict", %{proposal: p} do
      LLMStub.set_response("VERDICT: needs_revision | REASON: Conflicts with existing rule")

      assert {:ok, :needs_revision, _} = Critic.review(p, [])
    end

    test "returns error on unparseable response", %{proposal: p} do
      LLMStub.set_response("I'm not going to follow your format, sorry")

      assert {:error, {:unparseable_response, _}} = Critic.review(p, [])
    end

    test "is case-insensitive on verdict keyword", %{proposal: p} do
      LLMStub.set_response("VERDICT: Approve | REASON: Fine")

      assert {:ok, :approve, _} = Critic.review(p, [])
    end

    test "accepts whitespace around the format", %{proposal: p} do
      LLMStub.set_response("   VERDICT:  approve   |   REASON:   Clean   \n")

      assert {:ok, :approve, reason} = Critic.review(p, [])
      assert reason == "Clean"
    end
  end
end
