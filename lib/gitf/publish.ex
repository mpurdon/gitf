defmodule GiTF.Publish do
  @moduledoc """
  Delivery domain — gets a mission's work out of the dark factory and
  in front of human eyes (or onto `main`):

    * `merge/1` — the **sync** phase. Merges the mission's ghost
      branches into a single mission branch, then either lands directly
      on `main` (`auto_merge` strategy) or leaves the branch staged for
      the later PR open step (`pr_branch` strategy) or just records
      "manual" so an operator can take it over.
    * `step/1` — the **publish** phase, isolated. Transitions the
      mission into `publish`, runs the actual `do_publish` work
      (push / `gh pr create`) and stores the resulting artifact.
      Called by `GiTF.Phases.Publish.start/3` so the workflow path
      controls its own follow-up via `before_advance`/`terminal`.
    * `start/1` — the legacy advance loop's entry into publish:
      `step/1` plus the legacy `after_publish` post-routing
      (mark user-visibly completed → kick scoring, or fail mission
      on `pr_failed`/`push_failed`).

  Both the legacy orchestrator (`advance_via_legacy/2` dispatch map,
  validation/awaiting-approval pass branches) and the workflow path
  (`Phases.Publish`, `Phases.Sync`) call into this module.

  Phase starters (`Orchestrator.dispatch_phase/2` →
  `start_simplify`, `start_scoring`) stay on the orchestrator because
  they share `spawn_phase_ghost/4` with every other phase starter;
  this module reaches them via the public `dispatch_phase/2` API.
  """

  require Logger

  alias GiTF.{Archive, Missions, Major.Orchestrator, Telemetry}

  # -- Sync phase (merge) ----------------------------------------------------

  @doc """
  Merge all of the mission's ghost branches into a single mission branch
  and either land on main, stage for PR, or mark as manual — depending
  on the sector's `sync_strategy`.

  Mirrors the legacy `Orchestrator.start_merge/1`. Returns whatever
  status `Missions.transition_phase` ends up at.
  """
  @spec merge(map()) :: {:ok, String.t()} | {:error, term()}
  def merge(mission) do
    with {:ok, _} <-
           Missions.transition_phase(mission.id, "sync", "Validation passed, merging") do
      sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)

      strategy =
        if sector, do: Map.get(sector, :sync_strategy) || "auto_merge", else: "auto_merge"

      case strategy do
        "manual" ->
          Missions.store_artifact(mission.id, "sync", %{
            "status" => "manual",
            "note" => "Branches left for manual merge"
          })

          {:ok, "sync"}

        "pr_branch" ->
          finalize_merge_as_pr(mission, sector)

        _ ->
          finalize_merge_to_main(mission)
      end
    end
  end

  defp finalize_merge_to_main(mission) do
    with {:ok, sector} <- fetch_sector(mission.sector_id),
         {:ok, quest_branch} <- GiTF.Sync.merge_quest(mission.id) do
      repo_path = sector.path

      main_before_sha =
        case GiTF.Git.head_sha(repo_path) do
          {:ok, sha} -> sha
          _ -> nil
        end

      merge_message =
        case mission.goal do
          goal when is_binary(goal) and goal != "" ->
            "gitf: #{String.slice(goal, 0, 72)} (#{mission.id})"

          _ ->
            nil
        end

      with {:ok, main_branch} <- GiTF.Sync.detect_main_branch(repo_path),
           :ok <- GiTF.Git.checkout(repo_path, main_branch),
           :ok <- GiTF.Git.sync(repo_path, quest_branch, no_ff: true, message: merge_message),
           {:ok, merge_commit_sha} <- GiTF.Git.head_sha(repo_path) do
        Missions.store_artifact(mission.id, "sync", %{
          "status" => "success",
          "branch" => quest_branch,
          "merged_at" => DateTime.utc_now(),
          "merge_commit_sha" => merge_commit_sha,
          "main_before_sha" => main_before_sha,
          "main_branch" => main_branch,
          "revertible" => true
        })

        {:ok, mission} = Missions.get(mission.id)
        Orchestrator.dispatch_phase("simplify", mission)
      else
        {:error, reason} ->
          Logger.warning("Quest #{mission.id} merge of mission branch failed: #{inspect(reason)}")

          Missions.store_artifact(mission.id, "sync", %{
            "status" => "failed",
            "branch" => quest_branch,
            "error" => inspect(reason)
          })

          Missions.fail_quest(mission.id, "Sync failed: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        Missions.store_artifact(mission.id, "sync", %{
          "status" => "failed",
          "error" => inspect(reason)
        })

        Logger.warning("Quest #{mission.id} sync failed: #{inspect(reason)}")
        Missions.fail_quest(mission.id, "Sync failed: #{inspect(reason)}")
    end
  end

  defp finalize_merge_as_pr(mission, nil), do: finalize_merge_to_main(mission)

  # A failed sync is retried by the workflow's next advance tick —
  # merge_quest rebuilds the mission branch idempotently, so later attempts
  # merge whatever the fix loop has landed since. Sealing on attempt 1
  # killed msn-da9597 while its quality-fix ghost was mid-repair and the
  # branch content was actually correct. The cap keeps a truly
  # irreconcilable mission from retrying forever.
  @max_sync_attempts 3

  # pr_branch sync: create the local mission branch with all impl ghost
  # branches merged in. The push + `gh pr create` happens later in the
  # publish phase, after simplify and scoring have run, so any cleanup
  # commits are included in the PR.
  defp finalize_merge_as_pr(mission, _sector) do
    case GiTF.Sync.merge_quest(mission.id) do
      {:ok, quest_branch} ->
        Missions.store_artifact(mission.id, "sync", %{
          "status" => "branched",
          "branch" => quest_branch
        })

        {:ok, mission} = Missions.get(mission.id)
        Orchestrator.dispatch_phase("simplify", mission)

      {:error, reason} ->
        record_sync_failure(mission, reason)
    end
  rescue
    e ->
      Logger.warning("Quest #{mission.id} pr_branch finalization failed: #{Exception.message(e)}")
      record_sync_failure(mission, {:finalization_crash, Exception.message(e)})
  end

  defp record_sync_failure(mission, reason) do
    attempts =
      case Missions.get_artifact(mission.id, "sync") do
        %{"sync_attempts" => n} when is_integer(n) -> n + 1
        _ -> 1
      end

    Missions.store_artifact(mission.id, "sync", %{
      "status" => "failed",
      "error" => inspect(reason),
      "sync_attempts" => attempts
    })

    if attempts >= @max_sync_attempts do
      Logger.warning(
        "Quest #{mission.id} sync failed #{attempts}x (#{inspect(reason)}) — sealing failed"
      )

      Missions.fail_quest(
        mission.id,
        "Sync failed after #{attempts} attempts: #{inspect(reason)}"
      )
    else
      Logger.warning(
        "Quest #{mission.id} sync failed (attempt #{attempts}/#{@max_sync_attempts}): " <>
          "#{inspect(reason)} — will retry on next advance"
      )

      GiTF.Observability.Alerts.dispatch_webhook(
        :sync_retry,
        "Quest #{mission.id} sync attempt #{attempts} failed: #{inspect(reason)}",
        dedup_key: "sync_retry:#{mission.id}"
      )
    end
  end

  # -- Publish phase ---------------------------------------------------------

  @doc """
  Legacy advance-loop entry into publish: do the synchronous publish
  step, then run the post-routing — mark user-visibly completed and
  kick scoring, or fail loudly if the PR / push failed.

  The workflow path uses `step/1` + `Phases.Publish.before_advance/3`
  to do the same in pieces.
  """
  @spec start(map()) :: {:ok, String.t()} | {:error, term()}
  def start(mission) do
    with {:ok, _} <- step(mission) do
      after_step(mission)
    end
  end

  @doc """
  Post-publish routing: mark user-visibly completed + dispatch scoring
  on success, or fail the mission loudly on `pr_failed`/`push_failed`.

  Public so the legacy `check_and_advance(mission, "publish", _)` path
  in the orchestrator can re-run it when the publish artifact is
  present but the transition didn't take (e.g., `step/1` succeeded but
  `after_step/1` raised before flipping the user-visible status).
  """
  @spec after_step(map()) :: {:ok, String.t()} | {:error, term()}
  def after_step(mission) do
    after_publish(mission)
  end

  @doc """
  Workflow-path publish step: transition to `publish`, render the
  publish work, store the `publish` artifact, and start outcome
  tracking if a PR landed. Does NOT advance the mission — the workflow
  handler owns that.
  """
  @spec step(map()) :: {:ok, String.t()} | {:error, term()}
  def step(mission) do
    with {:ok, _} <-
           Missions.transition_phase(mission.id, "publish", "Simplify complete, publishing") do
      sync = Missions.get_artifact(mission.id, "sync") || %{}
      sector = if mission.sector_id, do: Archive.get(:sectors, mission.sector_id)

      result = do_publish(mission, sector, sync)

      Missions.store_artifact(mission.id, "publish", result)
      maybe_start_outcome_tracking(mission, result)

      {:ok, "publish"}
    end
  end

  # Runs after `publish`:
  #
  #   * When publish delivered (PR opened, push-to-main succeeded, or
  #     skipped explicitly), mark the mission user-visibly completed and
  #     kick scoring (async post-processing).
  #   * When publish FAILED to deliver (pr_failed / push_failed), fail
  #     the mission loudly. The pipeline's sole user-facing output is
  #     the PR — claiming "completed" without one is the worst kind of
  #     silent failure.
  defp after_publish(mission) do
    publish = Missions.get_artifact(mission.id, "publish") || %{}
    publish_status = Map.get(publish, "status")

    if publish_status in ["pr_failed", "push_failed"] do
      reason =
        "Publish failed: status=#{publish_status} error=#{inspect(Map.get(publish, "error"))}"

      Logger.warning("Quest #{mission.id}: #{reason} — marking mission failed")

      Telemetry.emit([:gitf, :mission, :publish_failed], %{}, %{
        mission_id: mission.id,
        status: publish_status
      })

      Missions.fail_quest(mission.id, reason)
    else
      Missions.mark_user_visible_completed(mission.id)

      Logger.info(
        "Quest #{mission.id}: publish done (status=#{publish_status || "unknown"}) — " <>
          "user-visible completed, starting async post-processing"
      )

      Telemetry.emit([:gitf, :mission, :user_visible_completed], %{}, %{
        mission_id: mission.id,
        name: mission[:name],
        publish_status: publish_status
      })

      # Reload to populate `ops` — Archive.update returns the raw record
      # but spawn_phase_ghost iterates mission.ops.
      {:ok, mission} = Missions.get(mission.id)
      Orchestrator.dispatch_phase("scoring", mission)
    end
  end

  defp maybe_start_outcome_tracking(mission, %{"pr_url" => pr_url} = result)
       when is_binary(pr_url) and pr_url != "" do
    status = Map.get(result, "status")

    # Only track when the PR is genuinely live. pr_failed / skipped have
    # no PR to watch.
    if status in ["pr_created", "pr_exists"] do
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        try do
          GiTF.Outcomes.start_tracking(mission, pr_url)
        rescue
          e ->
            Logger.warning(
              "Quest #{mission.id}: outcome tracking start failed: #{Exception.message(e)}"
            )
        end
      end)
    end
  end

  defp maybe_start_outcome_tracking(_mission, _result), do: :ok

  # Publish outcomes:
  #   * pr_branch strategy + branch present → push branch + open PR
  #   * auto_merge + repo has a configured remote → push the main branch
  #   * otherwise → skipped (local-only work is already in place)
  defp do_publish(_mission, nil, _sync) do
    %{"status" => "skipped", "reason" => "no sector"}
  end

  defp do_publish(mission, sector, sync) do
    strategy = Map.get(sector, :sync_strategy) || "auto_merge"
    branch = Map.get(sync, "branch")

    cond do
      strategy == "pr_branch" and is_binary(branch) and branch != "" ->
        publish_pr(mission, sector, branch)

      strategy == "auto_merge" and has_origin?(sector.path) ->
        publish_push_main(mission, sector, sync)

      true ->
        %{
          "status" => "skipped",
          "reason" =>
            "strategy=#{strategy}, branch=#{inspect(branch)}, remote=#{has_origin?(sector.path)}"
        }
    end
  end

  defp publish_pr(mission, sector, branch) do
    repo_path = sector.path

    case GiTF.Sync.detect_main_branch(repo_path) do
      {:ok, main_branch} ->
        push_result =
          GiTF.Git.safe_cmd(["push", "-u", "origin", branch],
            cd: repo_path,
            stderr_to_stdout: true
          )

        # Verify-then-use: a rejected push previously flowed straight into
        # find_existing_pr, "found" the stale PR for this head, and marked
        # the mission delivered without the work. Assert the push landed
        # and that origin's tip matches ours before touching PR state.
        with {_, 0} <- push_result,
             :ok <- verify_branch_pushed(repo_path, branch) do
          publish_pr_verified(mission, repo_path, branch, main_branch)
        else
          {output, code} when is_integer(code) ->
            Logger.error(
              "Quest #{mission.id} push failed (exit #{code}): #{String.slice(to_string(output), 0, 300)}"
            )

            %{"status" => "push_failed", "branch" => branch, "error" => to_string(output)}

          {:error, reason} ->
            Logger.error("Quest #{mission.id} push verification failed: #{reason}")
            %{"status" => "push_failed", "branch" => branch, "error" => reason}
        end

      {:error, reason} ->
        %{
          "status" => "push_failed",
          "branch" => branch,
          "error" => "no main branch: #{inspect(reason)}"
        }
    end
  end

  # Origin's tip for the branch must equal our local tip — a push that
  # "succeeded" against a pre-existing remote branch at an older SHA is
  # not delivery.
  defp verify_branch_pushed(repo_path, branch) do
    with {:ok, local} <- GiTF.Git.rev_parse(repo_path, branch),
         {:ok, remote} <- GiTF.Git.rev_parse(repo_path, "origin/#{branch}") do
      if local == remote,
        do: :ok,
        else:
          {:error,
           "origin/#{branch} is at #{String.slice(remote, 0, 8)}, local at #{String.slice(local, 0, 8)}"}
    else
      _ -> {:error, "could not resolve #{branch} / origin/#{branch} after push"}
    end
  end

  defp publish_pr_verified(mission, repo_path, branch, main_branch) do
    # Idempotent: if a PR already exists for this branch, reuse its
    # URL instead of hitting duplicate-PR error on recreate.
    result =
      case find_existing_pr(repo_path, branch) do
        {:ok, url} ->
          Logger.info("Quest #{mission.id} reusing existing PR: #{url}")
          %{"status" => "pr_exists", "branch" => branch, "pr_url" => url}

        :none ->
          title = "gitf: #{mission.name || mission.goal}" |> String.slice(0, 200)
          body = build_pr_body(mission) |> String.slice(0, 4000)

          case run_gh_pr_create_with_retry(repo_path, branch, main_branch, title, body) do
            {:ok, url} ->
              %{"status" => "pr_created", "branch" => branch, "pr_url" => url}

            {:error, reason} ->
              Logger.warning("Quest #{mission.id} publish PR failed: #{inspect(reason)}")
              %{"status" => "pr_failed", "branch" => branch, "error" => inspect(reason)}
          end
      end

    # Verify the URL we got back actually points at an OPEN PR.
    # `gh pr view <url> --json state` will fail if the URL is bogus
    # or the PR was closed/merged in the meantime — better to catch
    # it here than ship a publish artifact whose pr_url is dead.
    verify_pr_url(result, repo_path, mission.id)
  end

  defp verify_pr_url(%{"status" => status} = result, _repo_path, _mission_id)
       when status in ["pr_failed", "skipped"],
       do: result

  defp verify_pr_url(%{"pr_url" => url} = result, repo_path, mission_id) when is_binary(url) do
    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd("gh", ["pr", "view", url, "--json", "state", "--jq", ".state"],
          cd: repo_path,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        state = String.trim(output)

        if state == "OPEN" do
          Map.put(result, "pr_state", "OPEN")
        else
          Logger.warning(
            "Quest #{mission_id}: PR #{url} verify returned state=#{inspect(state)} " <>
              "(expected OPEN); marking publish failed"
          )

          %{
            "status" => "pr_failed",
            "branch" => Map.get(result, "branch"),
            "error" => "PR exists but state is #{state} (expected OPEN)",
            "pr_url" => url
          }
        end

      {:ok, {output, _}} ->
        Logger.warning(
          "Quest #{mission_id}: PR verify command failed for #{url}: " <>
            String.slice(output, 0, 200)
        )

        %{
          "status" => "pr_failed",
          "branch" => Map.get(result, "branch"),
          "error" => "PR verify failed: #{String.slice(output, 0, 200)}",
          "pr_url" => url
        }

      {:exit, reason} ->
        # gh missing/broken raises inside the task — without this clause
        # the whole publish crashed with a CaseClauseError.
        Logger.warning("Quest #{mission_id}: PR verify task exited: #{inspect(reason)}")

        %{
          "status" => "pr_failed",
          "branch" => Map.get(result, "branch"),
          "error" => "PR verify could not run (gh unavailable?): #{inspect(reason)}",
          "pr_url" => url
        }

      nil ->
        Logger.warning("Quest #{mission_id}: PR verify timed out for #{url}")

        %{
          "status" => "pr_failed",
          "branch" => Map.get(result, "branch"),
          "error" => "PR verify timed out after 15s",
          "pr_url" => url
        }
    end
  end

  defp verify_pr_url(result, _repo_path, _mission_id), do: result

  # `gh pr view --head <branch> --json url` returns the URL if a PR
  # exists for that head branch. Exit code 1 when none exists.
  defp find_existing_pr(repo_path, branch) do
    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd(
          "gh",
          ["pr", "view", branch, "--json", "url", "--jq", ".url"],
          cd: repo_path,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        url = String.trim(output)
        if valid_pr_url?(url), do: {:ok, url}, else: :none

      _ ->
        :none
    end
  end

  defp valid_pr_url?(url) do
    is_binary(url) and String.starts_with?(url, "https://") and
      String.contains?(url, "/pull/")
  end

  # Retries `gh pr create` up to 3 times on transient failures
  # (rate-limit, 5xx) with exponential backoff. Gives up on persistent
  # errors like branch protection, auth failure, or an already-merged
  # base. The shell-out lives in `GiTF.GitHub.CLI.create_pr/6`; the
  # retry loop lives in `GiTF.Resilience.retry_with_backoff/2`. Here we
  # just glue them together with a transient-error predicate.
  defp run_gh_pr_create_with_retry(repo_path, branch, main_branch, title, body) do
    GiTF.Resilience.retry_with_backoff(
      fn ->
        case GiTF.GitHub.CLI.create_pr(repo_path, branch, main_branch, title, body) do
          {:ok, url} ->
            if valid_pr_url?(url), do: {:ok, url}, else: {:error, {:invalid_pr_url, url}}

          err ->
            err
        end
      end,
      max_attempts: 3,
      retriable?: &transient_gh_error?/1
    )
  end

  defp transient_gh_error?(reason) when is_binary(reason) do
    r = String.downcase(reason)

    String.contains?(r, "rate limit") or String.contains?(r, "503") or
      String.contains?(r, "502") or String.contains?(r, "504") or
      String.contains?(r, "timed out") or String.contains?(r, "connection")
  end

  defp transient_gh_error?(_), do: false

  defp publish_push_main(mission, sector, _sync) do
    repo_path = sector.path

    case GiTF.Sync.detect_main_branch(repo_path) do
      {:ok, main_branch} ->
        case GiTF.Git.safe_cmd(["push", "origin", main_branch],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {_out, 0} ->
            %{"status" => "pushed", "branch" => main_branch}

          {out, _} ->
            Logger.warning(
              "Quest #{mission.id} publish push failed: #{String.slice(out, 0, 200)}"
            )

            %{
              "status" => "push_failed",
              "branch" => main_branch,
              "error" => String.slice(out, 0, 200)
            }
        end

      {:error, reason} ->
        %{"status" => "skipped", "error" => inspect(reason)}
    end
  end

  defp has_origin?(repo_path) do
    case GiTF.Git.safe_cmd(["remote", "get-url", "origin"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp build_pr_body(mission) do
    """
    Mission #{mission.id}

    **Goal:** #{mission.goal}
    #{unresolved_review_block(mission)}
    """
    |> GiTF.Signature.sign()
  end

  # When the design review was overruled (redesign budget exhausted), the
  # objection ships with the PR instead of evaporating: the person clicking
  # approve deserves to know a reviewer disagreed and what about.
  defp unresolved_review_block(mission) do
    case GiTF.Phases.Review.unresolved_objection(mission) do
      text when is_binary(text) ->
        """

        > [!WARNING]
        > **Design review objection was not resolved.** The redesign budget
        > was exhausted and this mission proceeded with the best available
        > design. The reviewer's remaining concern:
        >
        > #{String.replace(text, "\n", "\n> ")}
        """

      _ ->
        ""
    end
  end

  defp fetch_sector(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> {:error, :sector_not_found}
      sector -> {:ok, sector}
    end
  end
end
