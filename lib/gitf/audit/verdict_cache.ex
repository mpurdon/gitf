defmodule GiTF.Audit.VerdictCache do
  @moduledoc """
  The audit lane's half of execution-efficiency B4: a sector's validation
  command run on a byte-identical tree gives the same verdict, so the
  op-level audit (`GiTF.Audit.verify_job/2`) does not pay npm ci +
  typecheck + build again for a tree it has already judged. The exec
  lane (`GiTF.Major.GroundTruth`) has had this for a while; the audit,
  which runs the SAME command under the SAME sector lock, did not — on a
  mission with retries and chained worktrees that is minutes of lock
  time per repeat.

  Keyed by sector, validation command and `GiTF.Git.tree_fingerprint/1`
  (HEAD + status, residue excluded). Only pass/fail verdicts are stored:
  an infra exit (126/127) describes a broken toolchain, not a tree, and
  must never be reused. A nil fingerprint never caches, either way.
  """

  alias GiTF.Archive

  @collection :tree_verdicts
  @keep 200

  @doc "A cached verdict for this exact tree, or nil."
  @spec lookup(String.t(), String.t(), String.t() | nil) :: map() | nil
  def lookup(_sector_id, _command, nil), do: nil

  def lookup(sector_id, command, tree) do
    Archive.find_one(
      @collection,
      &(&1.sector_id == sector_id and &1.command == command and &1.tree == tree)
    )
  end

  @doc "Remembers a pass/fail verdict for the tree the command just ran on."
  @spec store(String.t(), String.t(), String.t() | nil, map()) :: :ok
  def store(_sector_id, _command, nil, _verdict), do: :ok

  def store(sector_id, command, tree, %{status: status} = verdict)
      when status in ["passed", "failed"] do
    {:ok, _} =
      Archive.insert(@collection, %{
        sector_id: sector_id,
        command: command,
        tree: tree,
        status: status,
        output: verdict.output,
        exit_code: verdict.exit_code,
        ran_at: DateTime.utc_now()
      })

    prune()
    :ok
  end

  def store(_sector_id, _command, _tree, _verdict), do: :ok

  defp prune do
    entries = Archive.all(@collection)

    if length(entries) > @keep do
      entries
      |> Enum.sort_by(& &1.ran_at, {:desc, DateTime})
      |> Enum.drop(@keep)
      |> Enum.each(&Archive.delete(@collection, &1.id))
    end
  end
end
