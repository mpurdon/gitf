defmodule GiTF.Major.DesignReportTest do
  @moduledoc """
  The brief is a model call over mission artifacts. What must hold regardless
  of what the model says: it never fires when there is nothing to compare, a
  malformed completion never lands as an artifact, and a good one does.
  """
  use ExUnit.Case, async: false

  import Mox

  alias GiTF.Major.DesignReport

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    prev = Application.get_env(:gitf, :llm_client)
    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)
    on_exit(fn -> Application.put_env(:gitf, :llm_client, prev) end)
    :ok
  end

  defp mission_with(artifacts) do
    {:ok, m} = GiTF.Missions.create(%{goal: "add configurable approve messages"})
    Enum.each(artifacts, fn {k, v} -> GiTF.Missions.store_artifact(m.id, k, v) end)
    m
  end

  defp design(name), do: %{"components" => [%{"name" => name, "files" => ["a.rs"]}]}

  defp reply(text) do
    expect(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _model, _messages, _opts ->
      {:ok, %{text: text}}
    end)
  end

  test "refuses to spend a call when no design artifacts exist" do
    m = mission_with(%{"requirements" => %{"title" => "x"}})
    # No expect/3 — a call here would fail verify_on_exit!.
    assert {:error, :no_designs} = DesignReport.generate(m.id)
  end

  test "stores the synthesised brief as the design_report artifact" do
    m = mission_with(%{"design_minimal" => design("A"), "design_normal" => design("B")})

    reply("""
    ```json
    {"headline": "Same shape, different rigor.",
     "convergence": "Both touch a.rs.",
     "designs": [{"strategy": "normal", "character": "careful", "notable": ["saw the race"], "missed": []}],
     "decision": "normal wins.",
     "watch_items": [{"concern": "cross-window save", "why_it_matters": "lost update"}]}
    ```
    """)

    assert {:ok, report} = DesignReport.generate(m.id)
    assert report["headline"] == "Same shape, different rigor."
    assert DesignReport.get(m.id)["decision"] == "normal wins."
  end

  test "records which strategies the brief was synthesised from" do
    m = mission_with(%{"design_minimal" => design("A"), "design_complex" => design("C")})
    reply(~s(```json\n{"headline": "h"}\n```))

    assert {:ok, report} = DesignReport.generate(m.id)
    # Not "normal" — absent designs must not be implied in the provenance.
    assert report["generated_from"] == ["minimal", "complex"]
  end

  test "a malformed completion is an error, not a stored artifact" do
    m = mission_with(%{"design_normal" => design("B")})
    reply("I could not produce JSON for this.")

    assert {:error, _} = DesignReport.generate(m.id)
    assert is_nil(DesignReport.get(m.id))
  end

  test "an empty completion does not overwrite an existing brief" do
    m = mission_with(%{"design_normal" => design("B")})
    reply(~s(```json\n{"headline": "first"}\n```))
    assert {:ok, _} = DesignReport.generate(m.id)

    reply("")
    assert {:error, :empty_completion} = DesignReport.generate(m.id)
    assert DesignReport.get(m.id)["headline"] == "first"
  end

  test "surfaces provider failures rather than storing a partial brief" do
    m = mission_with(%{"design_normal" => design("B")})

    expect(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _, _, _ ->
      {:error, :provider_unavailable}
    end)

    assert {:error, :provider_unavailable} = DesignReport.generate(m.id)
    assert is_nil(DesignReport.get(m.id))
  end
end
