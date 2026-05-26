defmodule GiTF.Eval.SkillsRetrieval do
  @moduledoc """
  Eval scenario: skills retrieval ranks the right global skill above
  noise for a representative goal.

  Each case fixes a goal text and the skill name that should appear in
  the top-K. A pass means the expected skill's rank is ≤ `min_rank`.
  Fails surface the actual top-K so regressions in embedding quality
  are immediately visible.

  Skipped when Bootstrap hasn't seeded the global skill library yet
  (otherwise the candidate pool is empty and every case "fails" for
  the wrong reason).
  """

  @behaviour GiTF.Eval.Scenario

  alias GiTF.Skills

  @impl true
  def name, do: "skills_retrieval"

  @impl true
  def description,
    do: "Skills retrieval ranks expected global skill within top-K for representative goals"

  @impl true
  def cases do
    [
      %{
        id: "lockfile_after_manifest_change",
        goal: "Update package.json to add a new dependency",
        expected_skill_name: "lockfile-after-manifest-change",
        min_rank: 3
      },
      %{
        id: "validator_evidence_concrete",
        goal: "Write a validator output explaining why the code is correct",
        expected_skill_name: "validator-evidence-must-be-concrete",
        min_rank: 3
      },
      %{
        id: "prefer_existing_utils",
        goal: "Add a helper function to format a timestamp",
        expected_skill_name: "prefer-existing-utils-over-new",
        min_rank: 3
      },
      %{
        id: "commit_meaningful_changes",
        goal: "Commit the changes after fixing the bug",
        expected_skill_name: "commit-meaningful-changes-only",
        min_rank: 3
      }
    ]
  end

  @impl true
  def run(case_map, opts) do
    if Skills.list_global() == [] do
      {:skip, "no global skills seeded — run Bootstrap.seed_global_skills/0 first"}
    else
      do_run(case_map, opts)
    end
  end

  defp do_run(case_map, opts) do
    op = %{
      title: case_map.goal,
      description: case_map.goal,
      goal: case_map.goal
    }

    top_k = Keyword.get(opts, :top_k, 5)

    {:ok, ranked} = Skills.Retrieval.retrieve(op, nil, top_k: top_k)
    rank = GiTF.Eval.Helpers.find_rank(ranked, case_map.expected_skill_name, & &1.name)
    names = Enum.map(ranked, & &1.name)

    GiTF.Eval.Helpers.rank_verdict(rank, names, case_map.min_rank, top_k)
  end
end
