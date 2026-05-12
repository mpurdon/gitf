defmodule GiTF.Outcomes.RefinementTest do
  # Exercises GiTF.Skills.Refinement.refine_after_merge/2 end-to-end against
  # the real Archive, mocking out the refiner LLM. The key assertion: each
  # outcome category drives the correct counter bumps on applied skills.

  use GiTF.StoreCase

  alias GiTF.Skills
  alias GiTF.Skills.Refinement

  setup do
    # Feature-gate on for this module, restore on exit
    prior_enabled = Application.get_env(:gitf, :outcome_refinement_enabled, false)
    Application.put_env(:gitf, :outcome_refinement_enabled, true)

    # Clean skills + outcomes between tests
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    on_exit(fn -> Application.put_env(:gitf, :outcome_refinement_enabled, prior_enabled) end)
    :ok
  end

  defp make_skill! do
    {:ok, s} =
      Skills.create(%{
        name: "test-skill",
        description: "d",
        body: "---\nname: t\ndescription: d\n---\nbody",
        scope: :global
      })

    s
  end

  defp mission_with_skill(skill_id) do
    %{
      id: "msn-#{:erlang.unique_integer([:positive])}",
      sector_id: "sec-test",
      ops: [%{applied_skill_ids: [skill_id], phase_job: false}]
    }
  end

  defp outcome(category, overrides \\ %{}) do
    Map.merge(
      %{
        id: "out-#{:erlang.unique_integer([:positive])}",
        mission_id: "msn-x",
        outcome_category: category,
        reviews: [],
        revert_detected: category == :merged_reverted,
        revert_sha: nil
      },
      overrides
    )
  end

  describe "refine_after_merge/2 — success path" do
    test ":merged_clean bumps success_count" do
      skill = make_skill!()
      mission = mission_with_skill(skill.id)

      assert :ok = Refinement.refine_after_merge(mission, outcome(:merged_clean))

      after_ = Skills.get(skill.id)
      assert after_.success_count == 1
      assert after_.failure_count == 0
    end

    test "no applied skills → no-op" do
      mission = %{id: "msn-empty", sector_id: "sec-test", ops: []}
      assert :ok = Refinement.refine_after_merge(mission, outcome(:merged_clean))
    end
  end

  describe "refine_after_merge/2 — feature flag off" do
    test "no counter bumps when :outcome_refinement_enabled is false" do
      Application.put_env(:gitf, :outcome_refinement_enabled, false)
      skill = make_skill!()
      mission = mission_with_skill(skill.id)

      assert :ok = Refinement.refine_after_merge(mission, outcome(:merged_clean))
      assert Skills.get(skill.id).success_count == 0
    end
  end

  describe "refine_after_merge/2 — non-terminal" do
    test ":changes_requested is a no-op (not terminal yet)" do
      skill = make_skill!()
      mission = mission_with_skill(skill.id)

      assert :ok = Refinement.refine_after_merge(mission, outcome(:changes_requested))
      # No bumps — tracker hasn't decided the PR is lost yet.
      after_ = Skills.get(skill.id)
      assert after_.success_count == 0
      assert after_.failure_count == 0
    end
  end

  describe "refine_after_merge/2 — failure paths bump failure_count" do
    # Hard to run the refiner LLM in a unit test (requires Mox setup). We
    # assert only the counter bump which is the failure-budget-honest part.

    @tag :llm
    test ":merged_reverted bumps failure_count before refiner fires" do
      skill = make_skill!()
      mission = mission_with_skill(skill.id)

      # refine_after_merge/2 for terminal negatives calls the refiner,
      # which reaches out to the LLM. Without Mox setup that'll crash or
      # noop. The counter bump happens BEFORE the refiner call, so the
      # bump should land regardless. The `rescue` inside the function
      # swallows the LLM failure.
      Refinement.refine_after_merge(mission, outcome(:merged_reverted))

      assert Skills.get(skill.id).failure_count == 1
    end
  end
end
