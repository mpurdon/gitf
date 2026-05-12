defmodule GiTF.Workflow.InferenceTest do
  use GiTF.StoreCase

  alias GiTF.Workflow.Inference

  defmodule MockLLM do
    @behaviour GiTF.Runtime.LLMClient

    @impl true
    def generate_text(_model, _messages, _opts) do
      payload = Process.get(:mock_inference_payload, ~s({"workflow":"standard","confidence":0.5,"rationale":"default"}))
      {:ok, %{message: %{content: [%{text: payload}]}}}
    end
  end

  setup do
    prior_enabled = Application.get_env(:gitf, :workflow_inference_enabled)
    prior_threshold = Application.get_env(:gitf, :workflow_inference_threshold)
    prior_llm = Application.get_env(:gitf, :llm_client)

    Application.put_env(:gitf, :workflow_inference_enabled, true)
    Application.put_env(:gitf, :workflow_inference_threshold, 0.7)
    Application.put_env(:gitf, :llm_client, MockLLM)

    on_exit(fn ->
      if prior_enabled,
        do: Application.put_env(:gitf, :workflow_inference_enabled, prior_enabled),
        else: Application.delete_env(:gitf, :workflow_inference_enabled)

      if prior_threshold,
        do: Application.put_env(:gitf, :workflow_inference_threshold, prior_threshold),
        else: Application.delete_env(:gitf, :workflow_inference_threshold)

      if prior_llm,
        do: Application.put_env(:gitf, :llm_client, prior_llm),
        else: Application.delete_env(:gitf, :llm_client)
    end)

    :ok
  end

  defp set_payload(payload), do: Process.put(:mock_inference_payload, payload)

  defp standard_templates do
    [
      %{name: "standard", description: "default"},
      %{name: "bug-fix", description: "fast fix"},
      %{name: "doc-only", description: "docs"},
      %{name: "spike", description: "exploration"}
    ]
  end

  describe "classify/2" do
    test "returns the workflow when above threshold" do
      set_payload(~s({"workflow":"bug-fix","confidence":0.9,"rationale":"500 on Safari iOS"}))

      assert {:ok, "bug-fix", 0.9, "500 on Safari iOS"} =
               Inference.classify("Login returns 500 on Safari iOS — fix it", templates: standard_templates())
    end

    test ":no_match when below threshold" do
      set_payload(~s({"workflow":"bug-fix","confidence":0.3,"rationale":"unsure"}))

      assert :no_match =
               Inference.classify("Refactor the auth module", templates: standard_templates())
    end

    test ":no_match when LLM picks an unknown template" do
      set_payload(~s({"workflow":"made-up","confidence":0.95,"rationale":"x"}))

      assert :no_match = Inference.classify("anything", templates: standard_templates())
    end

    test ":no_match when LLM returns garbage" do
      set_payload("definitely not json")
      assert :no_match = Inference.classify("anything", templates: standard_templates())
    end

    test ":no_match when feature flag is off" do
      Application.put_env(:gitf, :workflow_inference_enabled, false)
      set_payload(~s({"workflow":"bug-fix","confidence":0.99,"rationale":"x"}))
      assert :no_match = Inference.classify("anything", templates: standard_templates())
    end

    test "respects an explicit threshold override" do
      set_payload(~s({"workflow":"bug-fix","confidence":0.55,"rationale":"x"}))

      # Default threshold 0.7 → no match
      assert :no_match = Inference.classify("x", templates: standard_templates())

      # Explicit lower threshold → match
      assert {:ok, "bug-fix", 0.55, _} =
               Inference.classify("x", templates: standard_templates(), threshold: 0.5)
    end
  end
end
