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
  # {:pass, cmd} | {:fail, cmd, output} | {:pre_existing, cmd, output,
  # baseline_output} | nil (not configured / no worktree to run in).
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
        timeout = GiTF.Validator.validation_timeout_ms(sector)

        # The baseline runs under the same lock, immediately after a
        # failure, so the two verdicts describe the same moment and the
        # same toolchain.
        result =
          GiTF.WorktreeLock.with_lock({:sector, mission.sector_id}, fn ->
            case GiTF.Validator.run_custom_validation(shell, cmd, timeout) do
              {:error, kind, output} when kind != :tool_missing ->
                {:error, kind, output, baseline(mission, sector, wt, cmd, timeout)}

              other ->
                other
            end
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

          {:error, kind, output, {:fail, baseline_output}} ->
            # The command fails on the base commit too: the sector is
            # broken independently of this mission, and no fix ghost can
            # mend it inside the scope fence. msn-f24c5f: cora's main had
            # reqwest under a macOS-only dependency table; the CSS-only
            # mission "failed" its build and three fix ghosts rewrote
            # Cargo.toml chasing it.
            Logger.warning(
              "Validation command FAILED for #{mission.id} (#{kind}) and ALSO fails on the " <>
                "base commit — pre-existing, not attributable to this mission"
            )

            GiTF.Observability.Alerts.dispatch_webhook(
              :sector_baseline_broken,
              "Sector #{sector.name}: the validation command fails on the base commit " <>
                "(#{String.slice(to_string(baseline_output), 0, 200)}) — missions cannot " <>
                "pass their build until main is fixed",
              dedup_key: "sector_baseline_broken:#{sector.id}"
            )

            store_exec_verdict(mission, %{
              "status" => "fail",
              "infra_failure" => false,
              "pre_existing" => true,
              "kind" => to_string(kind),
              "output" => String.slice(to_string(output), 0, 500),
              "baseline_output" => String.slice(to_string(baseline_output), 0, 500),
              "tree" => post_fingerprint
            })

            {:pre_existing, cmd, to_string(output), to_string(baseline_output)}

          {:error, kind, output, _baseline_passes_or_unknown} ->
            fail_verdict(mission, kind, output, post_fingerprint, cmd)

          {:error, kind, output} ->
            fail_verdict(mission, kind, output, post_fingerprint, cmd)
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

  defp fail_verdict(mission, kind, output, post_fingerprint, cmd) do
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

  # -- Baseline ------------------------------------------------------------------
  #
  # Does the validation command pass on the commit this work branched
  # from? Asked only after a failure, answered once per base commit and
  # command (the answer cannot change while the commit is the same), and
  # measured in a scratch worktree so the mission's tree is untouched.
  # Returns {:pass, ""} | {:fail, output} | :unknown.

  @baselines :validation_baselines

  defp baseline(mission, sector, wt, cmd, timeout),
    do: baseline_verdict(sector, wt, Topology.detect_diff_base(mission), cmd, timeout, mission.id)

  @doc false
  def baseline_verdict(sector, wt, base_ref, cmd, timeout, mission_id \\ "n/a") do
    with {:ok, sha} <- GiTF.Git.merge_base(wt, "HEAD", base_ref) do
      key = "#{sector.id}:#{sha}:#{:erlang.phash2(cmd)}"

      case Archive.get(@baselines, key) do
        %{status: "pass"} ->
          {:pass, ""}

        %{status: "fail", output: output} ->
          {:fail, output}

        nil ->
          verdict = measure_baseline(mission_id, sector, sha, cmd, timeout)

          case verdict do
            {:pass, _} ->
              Archive.put(@baselines, %{
                id: key,
                status: "pass",
                output: "",
                at: DateTime.utc_now()
              })

            {:fail, out} ->
              Archive.put(@baselines, %{
                id: key,
                status: "fail",
                output: out,
                at: DateTime.utc_now()
              })

            :unknown ->
              :ok
          end

          verdict
      end
    else
      _ -> :unknown
    end
  rescue
    e ->
      Logger.warning("Baseline validation crashed for #{mission_id}: #{Exception.message(e)}")
      :unknown
  end

  defp measure_baseline(mission_id, sector, sha, cmd, timeout) do
    short = String.slice(sha, 0, 12)
    path = Path.join([sector.path, "ghosts", "baseline-#{short}"])
    branch = "gitf/baseline-#{short}"

    Logger.info("Quest #{mission_id}: measuring validation baseline at #{short}")

    if File.dir?(path) do
      GiTF.Git.worktree_remove(sector.path, path, force: true)
      File.rm_rf(path)
    end

    case GiTF.Git.worktree_add(sector.path, path, branch, sha) do
      {:ok, _} ->
        try do
          case GiTF.Validator.run_custom_validation(%{worktree_path: path}, cmd, timeout) do
            :ok -> {:pass, ""}
            {:error, :tool_missing, _} -> :unknown
            {:error, _kind, output} -> {:fail, String.slice(to_string(output), 0, 500)}
          end
        after
          GiTF.Git.worktree_remove(sector.path, path, force: true)
          File.rm_rf(path)
          GiTF.Git.safe_cmd(["branch", "-D", branch], cd: sector.path, stderr_to_stdout: true)
        end

      _ ->
        :unknown
    end
  end

  @doc """
  Records an infra verdict for a run that never produced one.

  `run_exec_validation/2` classifies every failure it SEES, but it can
  also fail to return at all — the command runner spawns a linked
  `Task`, so an `:enoent` raised by `System.cmd` (a missing sandbox
  binary, a worktree path that no longer exists) arrives at the caller as
  an EXIT that no `rescue` here or in `GiTF.Validator` can catch. The
  caller isolates that (see `PhaseLauncher.exec_validation_or_note/2`)
  and calls this so the verdict artifact still says "infrastructure" —
  which is what stops `Phases.Validation` burning a fix attempt on code
  that was never judged.
  """
  @spec store_infra_verdict(map(), String.t()) :: :ok
  def store_infra_verdict(mission, output) do
    store_exec_verdict(mission, %{
      "status" => "fail",
      "infra_failure" => true,
      "kind" => "runner_aborted",
      "output" => String.slice(output, 0, 500),
      # No fingerprint: nothing was measured, so nothing may be cached.
      "tree" => nil
    })

    :ok
  end

  # Tree identity lives beside the other git primitives.
  defp tree_fingerprint(wt), do: GiTF.Git.tree_fingerprint(wt)

  # One owner for the verdict-map ↔ return-tuple mapping, used by both the
  # cache-hit arm and the fresh-run arms.
  defp verdict_result(%{"status" => "pass"}, cmd), do: {:pass, cmd}

  defp verdict_result(%{"pre_existing" => true} = v, cmd),
    do: {:pre_existing, cmd, to_string(v["output"] || ""), to_string(v["baseline_output"] || "")}

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
