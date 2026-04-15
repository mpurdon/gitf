defmodule GiTF.Web.ApiController do
  @moduledoc "REST API controller for remote CLI access."

  use Phoenix.Controller, formats: [:json]

  require GiTF.Ghost.Status, as: GhostStatus

  # -- Health ------------------------------------------------------------------

  def health(conn, _params) do
    boot_time =
      try do
        :persistent_term.get(:gitf_boot_time)
      rescue
        _ -> 0
      end

    json(conn, %{
      data: %{
        status: "ok",
        node: to_string(node()),
        uptime_seconds: GiTF.Observability.Metrics.uptime_seconds(),
        boot_time: DateTime.from_unix!(boot_time) |> to_string(),
        version: GiTF.version()
      }
    })
  end

  # -- Metrics -----------------------------------------------------------------

  def metrics(conn, _params) do
    body = GiTF.Observability.Metrics.export_prometheus()

    conn
    |> put_resp_content_type("text/plain; version=0.0.4", nil)
    |> send_resp(200, body)
  end

  # -- Quests ------------------------------------------------------------------

  def create_quest(conn, params) do
    attrs =
      params
      |> Map.take(["goal", "sector_id", "priority"])
      |> atomize_keys()

    case GiTF.Missions.create(attrs) do
      {:ok, mission} -> json(conn, %{data: serialize_quest(mission)})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def list_quests(conn, params) do
    opts =
      case params["status"] do
        nil -> []
        status -> [status: status]
      end

    missions = GiTF.Missions.list(opts)

    missions =
      case params["sector_id"] do
        nil -> missions
        sector_id -> Enum.filter(missions, &(&1[:sector_id] == sector_id))
      end

    # Default to active only unless ?all=true
    missions =
      if params["all"] == "true" do
        missions
      else
        case params["status"] do
          nil -> Enum.reject(missions, &(&1[:status] in ["completed", "closed"]))
          _ -> missions
        end
      end

    json(conn, %{data: Enum.map(missions, &serialize_quest/1)})
  end

  def show_quest(conn, %{"id" => id}) do
    case GiTF.Missions.get(id) do
      {:ok, mission} -> json(conn, %{data: serialize_quest(mission)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def update_quest_priority(conn, %{"id" => id, "priority" => priority_str}) do
    case GiTF.Priority.parse(priority_str) do
      {:ok, priority} ->
        case GiTF.Missions.update_priority(id, priority) do
          {:ok, mission} -> json(conn, %{data: serialize_quest(mission)})
          {:error, :not_found} -> error(conn, 404, :not_found)
          {:error, reason} -> error(conn, 422, reason)
        end

      {:error, _} ->
        error(conn, 422, "Invalid priority. Use: critical, high, normal, low, background")
    end
  end

  def delete_quest(conn, %{"id" => id}) do
    case GiTF.Missions.delete(id) do
      :ok -> json(conn, %{data: %{deleted: true}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def kill_quest(conn, %{"id" => id}) do
    case GiTF.Missions.kill(id) do
      :ok -> json(conn, %{data: %{id: id, status: "killed"}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def close_quest(conn, %{"id" => id}) do
    case GiTF.Missions.close(id) do
      {:ok, mission} -> json(conn, %{data: serialize_quest(mission)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def start_quest(conn, %{"id" => id}) do
    case GiTF.Major.Orchestrator.start_quest(id) do
      {:ok, phase} -> json(conn, %{data: %{mission_id: id, phase: phase}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def plan_quest(conn, %{"id" => id}) do
    case GiTF.Major.Planner.generate_candidate_plans(id) do
      {:ok, plan} ->
        tasks = plan[:tasks] || plan.tasks || []

        # Read candidate count from mission record
        quest_record = GiTF.Archive.get(:missions, id)
        candidates = if quest_record, do: Map.get(quest_record, :plan_candidates, []), else: []

        json(conn, %{
          data: %{
            mission_id: id,
            goal: plan[:goal],
            selected_strategy: plan[:strategy],
            candidates_count: length(candidates),
            tasks:
              Enum.map(tasks, fn t ->
                %{
                  title: t["title"] || t[:title],
                  description: t["description"] || t[:description],
                  target_files: t["target_files"] || t[:target_files] || [],
                  acceptance_criteria: t["acceptance_criteria"] || t[:acceptance_criteria] || [],
                  depends_on_indices: t["depends_on_indices"] || t[:depends_on_indices] || [],
                  model_recommendation: t["model_recommendation"] || t[:model_recommendation]
                }
              end),
            estimated_duration: plan[:estimated_duration]
          }
        })

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def list_plan_candidates(conn, %{"id" => id}) do
    quest_record = GiTF.Archive.get(:missions, id)

    if quest_record do
      candidates = Map.get(quest_record, :plan_candidates, [])

      summary =
        Enum.map(candidates, fn c ->
          %{
            strategy: c[:strategy] || c.strategy,
            score: c[:score] || c.score,
            task_count: length(c[:tasks] || c.tasks || [])
          }
        end)

      json(conn, %{data: summary})
    else
      error(conn, 404, :not_found)
    end
  end

  def select_plan_candidate(conn, %{"id" => id} = params) do
    strategy = params["strategy"]
    quest_record = GiTF.Archive.get(:missions, id)

    cond do
      is_nil(quest_record) ->
        error(conn, 404, :not_found)

      is_nil(strategy) ->
        error(conn, 422, "strategy is required")

      true ->
        candidates = Map.get(quest_record, :plan_candidates, [])

        case Enum.find(candidates, fn c -> (c[:strategy] || c.strategy) == strategy end) do
          nil ->
            error(conn, 404, "candidate not found for strategy: #{strategy}")

          candidate ->
            updated = Map.put(quest_record, :draft_plan, candidate)
            GiTF.Archive.put(:missions, updated)

            tasks = candidate[:tasks] || candidate.tasks || []

            json(conn, %{
              data: %{
                mission_id: id,
                strategy: strategy,
                score: candidate[:score] || candidate.score,
                tasks:
                  Enum.map(tasks, fn t ->
                    %{
                      title: t["title"] || t[:title],
                      description: t["description"] || t[:description],
                      target_files: t["target_files"] || t[:target_files] || [],
                      acceptance_criteria:
                        t["acceptance_criteria"] || t[:acceptance_criteria] || [],
                      depends_on_indices: t["depends_on_indices"] || t[:depends_on_indices] || [],
                      model_recommendation: t["model_recommendation"] || t[:model_recommendation]
                    }
                  end),
                estimated_duration: candidate[:estimated_duration]
              }
            })
        end
    end
  end

  def quest_status(conn, %{"id" => id}) do
    case GiTF.Major.Orchestrator.get_quest_status(id) do
      {:ok, status} ->
        json(conn, %{
          data: %{
            mission: serialize_quest(status.mission),
            current_phase: status.current_phase,
            completed_phases: status.completed_phases,
            artifacts_summary: status.artifacts_summary,
            jobs_created: status.jobs_created,
            phase_history:
              Enum.map(status.phase_history || [], fn t ->
                %{from_phase: t[:from_phase], to_phase: t[:to_phase], reason: t[:reason]}
              end)
          }
        })

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_report(conn, %{"id" => id}) do
    case GiTF.Report.generate(id) do
      {:ok, report} ->
        json(conn, %{data: %{text: GiTF.Report.format(report), mission_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_merge(conn, %{"id" => id}) do
    case GiTF.Sync.merge_quest(id) do
      {:ok, branch} ->
        json(conn, %{data: %{branch: branch, mission_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_spec_show(conn, %{"id" => mission_id, "phase" => phase}) do
    case GiTF.Specs.read(mission_id, phase) do
      {:ok, content} ->
        json(conn, %{data: %{content: content, mission_id: mission_id, phase: phase}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_spec_write(conn, %{"id" => mission_id, "phase" => phase} = params) do
    content = params["content"] || ""

    case GiTF.Specs.write(mission_id, phase, content) do
      {:ok, path} ->
        json(conn, %{data: %{path: path, mission_id: mission_id, phase: phase}})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def confirm_plan(conn, %{"id" => mission_id} = params) do
    specs = params["specs"] || []

    {:ok, ops} = GiTF.Major.Planner.create_jobs_from_specs(mission_id, specs)
    GiTF.Missions.store_artifact(mission_id, "planning", specs)
    json(conn, %{data: %{mission_id: mission_id, jobs_created: length(ops)}})
  end

  def reject_plan(conn, %{"id" => mission_id} = params) do
    feedback = params["feedback"]

    # Clear the draft plan
    quest_record = GiTF.Archive.get(:missions, mission_id)

    if quest_record do
      updated = Map.delete(quest_record, :draft_plan)
      GiTF.Archive.put(:missions, updated)

      if feedback do
        GiTF.Missions.store_artifact(mission_id, "plan_rejection", %{
          "feedback" => feedback,
          "rejected_at" => DateTime.utc_now()
        })
      end

      json(conn, %{data: %{rejected: true}})
    else
      error(conn, 404, :not_found)
    end
  end

  def revise_plan(conn, %{"id" => mission_id} = params) do
    feedback = params["feedback"] || ""

    case GiTF.Major.Planner.generate_llm_plan(mission_id, %{feedback: feedback}) do
      {:ok, plan} ->
        # Archive as draft
        quest_record = GiTF.Archive.get(:missions, mission_id)

        if quest_record do
          updated = Map.put(quest_record, :draft_plan, plan)
          GiTF.Archive.put(:missions, updated)
        end

        json(conn, %{data: plan})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  # -- Jobs --------------------------------------------------------------------

  def list_jobs(conn, params) do
    opts =
      case params["mission_id"] do
        nil -> []
        id -> [mission_id: id]
      end

    ops = GiTF.Ops.list(opts)

    ops =
      if params["all"] == "true" do
        ops
      else
        case params["status"] do
          nil -> Enum.reject(ops, &(&1.status in ["done", "failed"]))
          status -> Enum.filter(ops, &(&1.status == status))
        end
      end

    json(conn, %{data: Enum.map(ops, &serialize_job/1)})
  end

  def show_job(conn, %{"id" => id}) do
    case GiTF.Ops.get(id) do
      {:ok, op} -> json(conn, %{data: serialize_job(op)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def reset_job(conn, %{"id" => id}) do
    case GiTF.Ops.reset(id) do
      {:ok, op} -> json(conn, %{data: serialize_job(op)})
      {:error, :not_found} -> error(conn, 404, :not_found)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def kill_job(conn, %{"id" => id}) do
    case GiTF.Ops.kill(id) do
      :ok -> json(conn, %{data: %{id: id, status: "killed"}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  # -- Ghosts ------------------------------------------------------------------

  def list_bees(conn, params) do
    ghosts = GiTF.Ghosts.list()

    ghosts =
      if params["all"] == "true" do
        ghosts
      else
        case params["status"] do
          nil -> Enum.reject(ghosts, &GhostStatus.terminal?(&1.status))
          status -> Enum.filter(ghosts, &(&1.status == status))
        end
      end

    json(conn, %{data: Enum.map(ghosts, &serialize_ghost/1)})
  end

  def stop_ghost(conn, %{"id" => id}) do
    case GiTF.Ghosts.stop(id) do
      :ok -> json(conn, %{data: %{stopped: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def complete_bee(conn, %{"id" => ghost_id}) do
    # Phase ops: extract artifact before completing
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} when not is_nil(ghost.op_id) ->
        maybe_collect_phase_artifact(ghost_id, ghost.op_id)

      _ ->
        :ok
    end

    case GiTF.Ghosts.complete(ghost_id) do
      :ok -> json(conn, %{data: %{completed: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def fail_bee(conn, %{"id" => ghost_id} = params) do
    reason = params["reason"] || "unknown"

    case GiTF.Ghosts.fail(ghost_id, reason) do
      :ok -> json(conn, %{data: %{failed: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  # -- Sectors -----------------------------------------------------------------

  def add_sector(conn, params) do
    path = params["path"]
    opts_map = params["opts"] || %{}

    opts =
      opts_map
      |> Enum.reduce([], fn
        {"name", v}, acc -> [{:name, v} | acc]
        {"sync_strategy", v}, acc -> [{:sync_strategy, v} | acc]
        {"validation_command", v}, acc -> [{:validation_command, v} | acc]
        _, acc -> acc
      end)

    case GiTF.Sector.add(path, opts) do
      {:ok, sector} -> json(conn, %{data: serialize_sector(sector)})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def list_sectors(conn, _params) do
    sectors = GiTF.Sector.list()
    json(conn, %{data: Enum.map(sectors, &serialize_sector/1)})
  end

  def show_sector(conn, %{"id" => id}) do
    case GiTF.Sector.get(id) do
      {:ok, sector} -> json(conn, %{data: serialize_sector(sector)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def remove_sector(conn, %{"id" => id}) do
    case GiTF.Sector.remove(id) do
      {:ok, _sector} -> json(conn, %{data: %{deleted: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def use_sector(conn, %{"id" => id}) do
    case GiTF.Sector.set_current(id) do
      {:ok, sector} -> json(conn, %{data: serialize_sector(sector)})
      {:error, :not_found} -> error(conn, 404, :not_found)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- Costs -------------------------------------------------------------------

  def costs_summary(conn, _params) do
    summary = GiTF.Costs.summary()

    json(conn, %{
      data: %{
        total_cost: summary.total_cost,
        total_input_tokens: summary.total_input_tokens,
        total_output_tokens: summary.total_output_tokens,
        by_model: summary.by_model,
        by_ghost: summary.by_ghost,
        by_category: summary.by_category
      }
    })
  end

  def record_cost(conn, params) do
    ghost_id = params["ghost_id"]

    if is_nil(ghost_id) do
      error(conn, 422, "ghost_id is required")
    else
      attrs =
        %{
          input_tokens: params["input_tokens"] || 0,
          output_tokens: params["output_tokens"] || 0,
          cache_read_tokens: params["cache_read_tokens"] || 0,
          cache_write_tokens: params["cache_write_tokens"] || 0,
          model: params["model"],
          cost_usd: params["cost_usd"]
        }
        |> then(fn a ->
          if params["category"], do: Map.put(a, :category, params["category"]), else: a
        end)

      {:ok, cost} = GiTF.Costs.record(ghost_id, attrs)

      json(conn, %{
        data: %{
          id: cost.id,
          ghost_id: cost.ghost_id,
          cost_usd: cost.cost_usd,
          input_tokens: cost.input_tokens,
          output_tokens: cost.output_tokens,
          model: cost.model,
          category: cost.category
        }
      })
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp error(conn, status, reason) do
    message =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        bin when is_binary(bin) -> bin
        other -> inspect(other)
      end

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp maybe_collect_phase_artifact(ghost_id, op_id) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         true <- Map.get(op, :phase_job, false),
         phase when is_binary(phase) <- Map.get(op, :phase) do
      # Read the ghost's log file and extract the JSON artifact
      case find_bee_log(ghost_id) do
        {:ok, log_content} ->
          # Parse stream-json events to extract assistant text
          events =
            log_content
            |> String.split("\n", trim: true)
            |> Enum.reduce([], fn line, acc ->
              case Jason.decode(line) do
                {:ok, event} -> [event | acc]
                _ -> acc
              end
            end)
            |> Enum.reverse()

          case GiTF.Major.PhaseCollector.collect(phase, log_content, events) do
            {:ok, artifact} ->
              GiTF.Missions.store_artifact(op.mission_id, phase, artifact)

            {:error, reason} ->
              require Logger
              Logger.warning("Phase artifact extraction failed for #{phase}: #{inspect(reason)}")
          end

        {:error, _} ->
          :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp find_bee_log(ghost_id) do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        log_path = Path.join([gitf_root, ".gitf", "run", "#{ghost_id}.log"])

        if File.exists?(log_path) do
          File.read(log_path)
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :no_gitf_root}
    end
  end

  defp atomize_keys(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      try do
        [{String.to_existing_atom(k), v}]
      rescue
        ArgumentError -> []
      end
    end)
    |> Map.new()
  end

  defp serialize_quest(q) do
    %{
      id: q[:id],
      name: q[:name],
      status: q[:status] || "pending",
      goal: q[:goal],
      sector_id: q[:sector_id],
      current_phase: q[:current_phase],
      priority: q[:priority] || :normal,
      priority_source: q[:priority_source],
      effective_priority: GiTF.Priority.effective_priority(q),
      inserted_at: to_string(q[:inserted_at]),
      ops:
        case q[:ops] do
          nil -> []
          ops -> Enum.map(ops, &serialize_job/1)
        end
    }
  end

  defp serialize_job(j) do
    %{
      id: j.id,
      title: j.title,
      status: j.status,
      mission_id: j.mission_id,
      sector_id: j[:sector_id],
      ghost_id: j[:ghost_id],
      description: j[:description],
      inserted_at: to_string(j[:inserted_at])
    }
  end

  defp serialize_ghost(b) do
    %{
      id: b.id,
      name: b.name,
      status: b.status,
      op_id: b[:op_id],
      context_percentage: b[:context_percentage]
    }
  end

  defp serialize_sector(c) do
    %{
      id: c.id,
      name: c.name,
      path: c[:path],
      repo_url: c[:repo_url],
      sync_strategy: c[:sync_strategy],
      validation_command: c[:validation_command],
      github_owner: c[:github_owner],
      github_repo: c[:github_repo]
    }
  end
end
