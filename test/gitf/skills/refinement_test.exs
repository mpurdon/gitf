defmodule GiTF.Skills.RefinementTest do
  use ExUnit.Case, async: false

  alias GiTF.Skills
  alias GiTF.Skills.Refinement

  defmodule LLMStub do
    @behaviour GiTF.Runtime.LLMClient

    def set_responses(queue) do
      :persistent_term.put({__MODULE__, :queue}, queue)
    end

    @impl true
    def generate_text(_model, _messages, _opts) do
      case :persistent_term.get({__MODULE__, :queue}, []) do
        [head | rest] ->
          :persistent_term.put({__MODULE__, :queue}, rest)
          {:ok, %{message: %{content: [%{text: head}]}}}

        [] ->
          {:ok, %{message: %{content: [%{text: ""}]}}}
      end
    end

    @impl true
    def stream_text(_model, _messages, _opts), do: {:error, :not_implemented}
  end

  setup do
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    prev_llm = Application.get_env(:gitf, :llm_client)
    prev_refine = Application.get_env(:gitf, :skill_refinement_enabled)
    prev_commit = Application.get_env(:gitf, :skill_auto_commit_enabled)

    Application.put_env(:gitf, :llm_client, LLMStub)
    Application.put_env(:gitf, :skill_refinement_enabled, true)
    Application.put_env(:gitf, :skill_auto_commit_enabled, true)

    on_exit(fn ->
      :persistent_term.erase({LLMStub, :queue})
      restore(:llm_client, prev_llm)
      restore(:skill_refinement_enabled, prev_refine)
      restore(:skill_auto_commit_enabled, prev_commit)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:gitf, key)
  defp restore(key, value), do: Application.put_env(:gitf, key, value)

  describe "refine_after_validation/3 — pass path" do
    test "bumps success_count on applied skills" do
      {:ok, a} = Skills.create(%{name: "a", description: "d", body: "b", scope: :global})
      {:ok, b} = Skills.create(%{name: "b", description: "d", body: "b", scope: :global})

      mission = %{id: "msn-x", goal: "g"}
      validation = %{"overall_verdict" => "pass", "gaps" => []}

      Refinement.refine_after_validation(mission, validation, [a.id, b.id])

      assert Skills.get(a.id).success_count == 1
      assert Skills.get(b.id).success_count == 1
      assert Skills.get(a.id).failure_count == 0
    end

    test "is a no-op when no skills applied" do
      mission = %{id: "msn-x", goal: "g"}
      validation = %{"overall_verdict" => "pass"}

      assert :ok = Refinement.refine_after_validation(mission, validation, [])
    end
  end

  describe "refine_after_validation/3 — fail path" do
    test "bumps failure_count on applied skills (even without LLM)" do
      {:ok, a} = Skills.create(%{name: "a", description: "d", body: "b", scope: :global})

      # Queue: refiner says no_op, no critic call needed
      LLMStub.set_responses([
        ~s({"action":"no_op","rationale":"too specific"})
      ])

      mission = %{id: "msn-y", goal: "g"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["thing broke"]}

      Refinement.refine_after_validation(mission, validation, [a.id])

      assert Skills.get(a.id).failure_count == 1
    end

    test "drafts a new skill when refiner + critic approve" do
      LLMStub.set_responses([
        # Refiner proposes a draft_new
        ~s({
          "action":"draft_new",
          "target_skill_id":null,
          "name":"new-rule",
          "description":"Always X",
          "body":"---\\nname: new-rule\\ndescription: Always X\\n---\\nbody",
          "scope":"global",
          "rationale":"validation showed missing X"
        }),
        # Critic approves
        "VERDICT: approve | REASON: Specific and generalizable"
      ])

      mission = %{id: "msn-z", goal: "g", sector_id: "sec-A"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["missing X"]}

      before_count = length(Skills.all())

      Refinement.refine_after_validation(mission, validation, [])

      after_skills = Skills.all()
      assert length(after_skills) == before_count + 1

      new_skill = Enum.find(after_skills, &(&1.name == "new-rule"))
      assert new_skill != nil
      assert new_skill.source == :auto_drafted
      assert new_skill.scope == :global
    end

    test "refines an existing skill when refiner + critic approve" do
      {:ok, existing} =
        Skills.create(%{
          name: "old-rule",
          description: "old version",
          body: "old body",
          scope: :global
        })

      LLMStub.set_responses([
        ~s({
          "action":"refine_existing",
          "target_skill_id":"#{existing.id}",
          "name":"old-rule",
          "description":"sharper version",
          "body":"---\\nname: old-rule\\n---\\nnew body",
          "scope":"global",
          "rationale":"sharpen the rule"
        }),
        "VERDICT: approve | REASON: Better now"
      ])

      mission = %{id: "msn-w", goal: "g"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["stuff"]}

      Refinement.refine_after_validation(mission, validation, [existing.id])

      reloaded = Skills.get(existing.id)
      assert reloaded.description == "sharper version"
      assert reloaded.source == :auto_refined
      # Embedding should be cleared so retrieval re-embeds the refined body
      assert reloaded.embedding == nil
      # Failure counter was bumped (existing skill was applied to failed mission)
      assert reloaded.failure_count == 1
    end

    test "does not commit when critic rejects" do
      LLMStub.set_responses([
        ~s({
          "action":"draft_new",
          "target_skill_id":null,
          "name":"bad-draft",
          "description":"vague",
          "body":"---\\nname: bad-draft\\n---\\nbody",
          "scope":"global",
          "rationale":"because"
        }),
        "VERDICT: reject | REASON: Too vague"
      ])

      mission = %{id: "msn-v", goal: "g"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["x"]}

      before_count = length(Skills.all())
      Refinement.refine_after_validation(mission, validation, [])

      assert length(Skills.all()) == before_count,
             "rejected draft should not land in Archive"
    end

    test "does not commit when auto_commit is disabled (shadow mode)" do
      Application.put_env(:gitf, :skill_auto_commit_enabled, false)

      LLMStub.set_responses([
        ~s({
          "action":"draft_new",
          "target_skill_id":null,
          "name":"shadow-draft",
          "description":"ok",
          "body":"---\\nname: shadow-draft\\n---\\nbody",
          "scope":"global",
          "rationale":"because"
        }),
        "VERDICT: approve | REASON: Good"
      ])

      mission = %{id: "msn-s", goal: "g"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["x"]}

      before_count = length(Skills.all())
      Refinement.refine_after_validation(mission, validation, [])

      assert length(Skills.all()) == before_count,
             "shadow-mode approved draft should not land in Archive"
    end

    test "no_op action skips critic + commit" do
      LLMStub.set_responses([
        ~s({"action":"no_op","rationale":"too mission-specific"})
      ])

      mission = %{id: "msn-n", goal: "g"}
      validation = %{"overall_verdict" => "fail", "gaps" => ["x"]}

      before_count = length(Skills.all())
      Refinement.refine_after_validation(mission, validation, [])

      assert length(Skills.all()) == before_count
    end
  end
end
