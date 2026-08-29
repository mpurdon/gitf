defmodule GiTF.Major.GroundTruth do
  @moduledoc """
  THE GROUND TRUTH — the factory's own, non-negotiable read on whether
  the tree actually builds. Runs the sector's `validation_command` in
  the canonical worktree and records the verdict out-of-band, so the
  validation prompt is anchored to something a model cannot paraphrase
  away.

  This is the ONLY place the validation command runs on the normal
  pipeline; `GiTF.Validator.validate` is otherwise reached just via the
  conflict-rebase path.

  Named because the incidents here are all about trusting the wrong
  witness:

    * Run 7 (msn-4fda11): the fix loop's infra guard depended on the LLM
      validator echoing sentinel strings into its artifact. The validator
      paraphrased ("host toolchain error"), the guard missed, and four
      fix attempts were spent on a corrupted node_modules. The factory's
      own classification is now stored in the verdict artifact instead.
      The same run also proved the sector lock is mandatory: two `npm ci`
      racing in one tree corrupted node_modules.
    * Execution-efficiency B4: a fix loop re-enters validation several
      times per mission, and re-paying `npm ci` + build (minutes of
      sector-lock time) buys nothing when the tree has not moved. The
      verdict is cached against a tree fingerprint taken AFTER the run —
      the command mutates the tree (installs rewrite lockfiles), and the
      verdict describes the tree it LEFT behind, which is what the next
      round will see.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Major.Topology

  # Runs the sector's validation_command in the implementation ghost's
  # worktree and returns ground truth for the validation prompt:
  # {:pass, cmd} | {:fail, cmd, output} | nil (not configured / no
  # worktree to run in).
  @doc false
  def run_exec_validation(mission, variant_id) do
    with %{validation_command: cmd} = sector when is_binary(cmd) and cmd != "" <-
           Archive.get(:sectors, mission.sector_id),
         %{worktree_path: wt} = shell <- Topology.exec_validation_shell(mission, variant_id) do
      # Verdict cache (execution-efficiency B4): a fix loop re-enters
      # validation several times per mission; when the TREE hasn't moved
      # since the last run, re-paying npm ci + build (minutes of
      # sector-lock time) buys nothing. Reuse only on an exact
      # fingerprint match; a nil fingerprint never caches.
      fingerprint = tree_fingerprint(wt)
      cached = GiTF.Missions.get_artifact(mission.id, "exec_validation")

      if is_binary(fingerprint) and is_map(cached) and cached["tree"] == fingerprint do
        Logger.info(
          "Quest #{mission.id}: exec-validation tree unchanged — reusing #{cached["status"]} verdict"
        )

        verdict_result(cached, cmd)
      else
        Logger.info("Running validation command for #{mission.id}: #{cmd}")

        # Sector lock: the op-level audit runs this same command; two npm ci
        # racing in one tree corrupted node_modules on run 7 (msn-4fda11).
        result =
          GiTF.WorktreeLock.with_lock({:sector, mission.sector_id}, fn ->
            GiTF.Validator.run_custom_validation(
              shell,
              cmd,
              GiTF.Validator.validation_timeout_ms(sector)
            )
          end)

        # Fingerprint AFTER the run — the command itself mutates the tree
        # (installs rewrite lockfiles), and the verdict describes the tree
        # it LEFT behind, which is what the next round will see.
        post_fingerprint = tree_fingerprint(wt)

        case result do
          :ok ->
            Logger.info("Validation command passed for #{mission.id}")
            store_exec_verdict(mission, %{"status" => "pass", "tree" => post_fingerprint})
            {:pass, cmd}

          {:error, kind, output} ->
            Logger.warning(
              "Validation command FAILED for #{mission.id} (#{kind}): #{String.slice(to_string(output), 0, 300)}"
            )

            # Record the FACTORY's own classification out-of-band. The fix
            # loop's infra guard previously depended on the LLM validator
            # echoing sentinel strings into its artifact — run 7's validator
            # paraphrased ("host toolchain error") and the guard missed,
            # spending 4 fix attempts on a corrupted node_modules.
            store_exec_verdict(mission, %{
              "status" => "fail",
              "infra_failure" => kind == :tool_missing,
              "kind" => to_string(kind),
              "output" => String.slice(to_string(output), 0, 500),
              "tree" => post_fingerprint
            })

            {:fail, cmd, to_string(output)}
        end
      end
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("run_exec_validation crashed for #{mission.id}: #{Exception.message(e)}")
      nil
  end

  # Tree identity lives beside the other git primitives.
  defp tree_fingerprint(wt), do: GiTF.Git.tree_fingerprint(wt)

  # One owner for the verdict-map ↔ return-tuple mapping, used by both the
  # cache-hit arm and the fresh-run arms.
  defp verdict_result(%{"status" => "pass"}, cmd), do: {:pass, cmd}
  defp verdict_result(verdict, cmd), do: {:fail, cmd, to_string(verdict["output"] || "")}

  # Overwritten every round so a stale infra flag can never suppress fix
  # attempts for a later genuine code failure.
  defp store_exec_verdict(mission, verdict) do
    GiTF.Missions.store_artifact(mission.id, "exec_validation", verdict)
  rescue
    e ->
      Logger.warning(
        "Could not store exec_validation verdict for #{mission.id}: #{Exception.message(e)}"
      )
  end
end
