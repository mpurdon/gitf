defmodule GiTF.MissionsInferenceAsyncTest do
  @moduledoc """
  Verifies that workflow inference runs OFF the synchronous
  `Missions.create/1` path. With async enabled (default), the mission
  ships with the sector default and the classifier updates
  `workflow_id` later. With async disabled (the test here), we can
  assert the classifier ran synchronously after insert.
  """

  use GiTF.StoreCase

  alias GiTF.Missions

  defmodule MockLLM do
    @behaviour GiTF.Runtime.LLMClient

    @impl true
    def generate_text(_model, _messages, _opts) do
      payload = Process.get(:mock_payload, ~s({"workflow":"bug-fix","confidence":0.9,"rationale":"fast fix"}))
      {:ok, %{message: %{content: [%{text: payload}]}}}
    end
  end

  setup do
    prior_enabled = Application.get_env(:gitf, :workflow_inference_enabled)
    prior_async = Application.get_env(:gitf, :workflow_inference_async)
    prior_llm = Application.get_env(:gitf, :llm_client)

    Application.put_env(:gitf, :workflow_inference_enabled, true)
    Application.put_env(:gitf, :workflow_inference_async, false)
    Application.put_env(:gitf, :llm_client, MockLLM)

    on_exit(fn ->
      restore(:workflow_inference_enabled, prior_enabled)
      restore(:workflow_inference_async, prior_async)
      restore(:llm_client, prior_llm)
    end)

    :ok
  end

  defp restore(key, prior) do
    if is_nil(prior),
      do: Application.delete_env(:gitf, key),
      else: Application.put_env(:gitf, key, prior)
  end

  test "missions ship with sector default; classifier updates workflow_id when confident" do
    Process.put(:mock_payload, ~s({"workflow":"bug-fix","confidence":0.9,"rationale":"fast fix"}))

    {:ok, mission} = Missions.create(%{goal: "Fix login flow showing 500 on Safari iOS"})

    # With async disabled the classifier ran synchronously; pull the
    # latest record to see the post-update state.
    updated = GiTF.Archive.get(:missions, mission.id)

    assert updated.workflow_id == "bug-fix"
    assert updated.artifacts["workflow_inference"]["selected"] == "bug-fix"
    assert updated.artifacts["workflow_inference"]["confidence"] == 0.9
  end

  test "no-match leaves the sector default in place" do
    Process.put(:mock_payload, ~s({"workflow":"bug-fix","confidence":0.3,"rationale":"unsure"}))

    {:ok, mission} = Missions.create(%{goal: "Refactor the auth module"})
    updated = GiTF.Archive.get(:missions, mission.id)

    assert updated.workflow_id == "standard"
    refute Map.has_key?(updated.artifacts, "workflow_inference")
  end

  test "explicit workflow_id skips inference entirely" do
    Process.put(:mock_payload, ~s({"workflow":"bug-fix","confidence":0.99,"rationale":"x"}))

    {:ok, mission} = Missions.create(%{goal: "Fix bug", workflow_id: "spike"})
    updated = GiTF.Archive.get(:missions, mission.id)

    assert updated.workflow_id == "spike"
    refute Map.has_key?(updated.artifacts, "workflow_inference")
  end
end
