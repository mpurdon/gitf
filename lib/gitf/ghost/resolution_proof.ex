defmodule GiTF.Ghost.ResolutionProof do
  @moduledoc """
  THE RESOLUTION PROOF GATE — the one check standing between "a resolution
  ghost said it reconciled the markers" and the tree being merged forward
  as if it had.

  `GiTF.Ops.completion_proof/1` declares that merge-resolution ops prove
  completion by `{:absence_of_markers, files}`. This module evaluates that
  claim against the worktree the ghost actually left behind.

  ## Fail closed

  Every earlier version of this check rescued to `[]` — which reads as
  *proof passed*. A missing shell record, a pruned worktree, an empty
  target-file list and a raising git call all certified the resolution.
  Run 5 died of exactly that: an op whose markers were still in the tree
  went `"done"`, consolidation merged those markers forward, and the
  mission spent the rest of its budget resolving them a second time.

  A proof that cannot be evaluated is not a proof. Every non-verifiable
  path returns `{:unverifiable, why}` and the op fails — which also feeds
  the endgame's futility counter an honest sample instead of a forged
  pass, so non-convergence is noticed rather than laundered.

  ## Ordering

  The gate reads the COMMITTED tree, because what consolidation merges next
  is `HEAD`, not the ghost's working copy. The caller must run its
  auto-commit before calling `verify/1` — `GiTF.Ghost.Worker.mark_success/1`
  pins that ordering with a comment at the call site.
  """

  require Logger

  alias GiTF.Archive

  @type verdict :: :ok | {:markers, [String.t()]} | {:unverifiable, String.t()}

  @doc """
  Evaluates the absence-of-markers proof for one op.

  Takes the identifiers rather than the Worker's state struct so the gate
  can be exercised without a live ghost.

  Returns `:ok` (proof holds), `{:markers, files}` (verified negative — the
  ghost lied) or `{:unverifiable, why}` (the proof could not be evaluated
  at all, which fails the op just the same).

  Logs at info on EVERY evaluation, verdict included: the next miss must be
  diagnosable from journald alone, without a console probe on the box.
  """
  @spec verify(map()) :: verdict()
  def verify(%{op_id: op_id, ghost_id: ghost_id, shell_id: shell_id, files: files}) do
    shell = Archive.get(:shells, shell_id)
    worktree = if is_map(shell), do: shell[:worktree_path], else: nil

    verdict = evaluate(shell, shell_id, worktree, files)
    log(op_id, ghost_id, worktree, files, verdict)
    verdict
  rescue
    e ->
      verdict = {:unverifiable, "gate evaluation raised: #{Exception.message(e)}"}
      log(op_id, ghost_id, nil, files, verdict)
      verdict
  end

  @doc """
  The op-failure reason for a verdict, or nil when the proof holds. Keeps
  the wording of "this ghost lied" and "this ghost could not be checked"
  in one place — a post-mortem greps for these strings.
  """
  @spec failure_reason(verdict()) :: String.t() | nil
  def failure_reason(:ok), do: nil

  def failure_reason({:markers, files}),
    do: "Resolution reported success but conflict markers remain in: " <> Enum.join(files, ", ")

  def failure_reason({:unverifiable, why}),
    do: "resolution proof could not be verified (#{why})"

  # -- Internals ---------------------------------------------------------------

  defp evaluate(nil, shell_id, _worktree, _files),
    do: {:unverifiable, "shell #{inspect(shell_id)} not found"}

  defp evaluate(_shell, shell_id, worktree, _files) when not is_binary(worktree),
    do: {:unverifiable, "shell #{shell_id} has no worktree path"}

  defp evaluate(_shell, _shell_id, worktree, files) do
    cond do
      not File.dir?(worktree) ->
        {:unverifiable, "worktree #{worktree} is not on disk"}

      # Scoped to the op's own target files: marker-like content elsewhere
      # is validation's problem (adjudication), not this ghost's. An op with
      # NO target files therefore has nothing to prove — which is not the
      # same as having proved it.
      files == [] ->
        {:unverifiable, "op declared no target files to check"}

      true ->
        # The CHECKED variant: plain `conflict_marker_files/2` returns []
        # on a git failure, and [] is the proof. A git that cannot run must
        # not be able to certify a resolution. `-l` mode also returns
        # filenames uncapped, so a chatty first file can't hide a second
        # marker-laden one behind an excerpt's line limit.
        case GiTF.Git.conflict_marker_files_checked(worktree, files) do
          {:ok, []} -> :ok
          {:ok, marked} -> {:markers, marked}
          {:error, why} -> {:unverifiable, why}
        end
    end
  end

  defp log(op_id, ghost_id, worktree, files, verdict) do
    summary =
      case verdict do
        :ok -> "clean"
        {:markers, marked} -> "MARKERS in #{Enum.join(marked, ", ")}"
        {:unverifiable, why} -> "UNVERIFIABLE: #{why}"
      end

    Logger.info(
      "Resolution proof gate: op=#{op_id} ghost=#{ghost_id} " <>
        "worktree=#{worktree || "<none>"} files=#{inspect(files)} result=#{summary}"
    )
  end
end
