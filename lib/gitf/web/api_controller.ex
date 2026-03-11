defmodule GiTF.Web.ApiController do
  @moduledoc "REST API controller for remote CLI access."

  use Phoenix.Controller, formats: [:json]

  # -- Health ------------------------------------------------------------------

  def health(conn, _params) do
    json(conn, %{
      data: %{
        status: "ok",
        node: to_string(node()),
        uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
        version: GiTF.version()
      }
    })
  end

  # -- Quests ------------------------------------------------------------------

  def create_quest(conn, params) do
    attrs =
      params
      |> Map.take(["goal", "comb_id"])
      |> atomize_keys()

    case GiTF.Quests.create(attrs) do
      {:ok, quest} -> json(conn, %{data: serialize_quest(quest)})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def list_quests(conn, params) do
    opts =
      case params["status"] do
        nil -> []
        status -> [status: status]
      end

    quests = GiTF.Quests.list(opts)

    quests =
      case params["comb_id"] do
        nil -> quests
        comb_id -> Enum.filter(quests, &(&1[:comb_id] == comb_id))
      end

    # Default to active only unless ?all=true
    quests =
      if params["all"] == "true" do
        quests
      else
        case params["status"] do
          nil -> Enum.reject(quests, &(&1[:status] in ["completed", "closed"]))
          _ -> quests
        end
      end

    json(conn, %{data: Enum.map(quests, &serialize_quest/1)})
  end

  def show_quest(conn, %{"id" => id}) do
    case GiTF.Quests.get(id) do
      {:ok, quest} -> json(conn, %{data: serialize_quest(quest)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def delete_quest(conn, %{"id" => id}) do
    case GiTF.Quests.delete(id) do
      :ok -> json(conn, %{data: %{deleted: true}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def kill_quest(conn, %{"id" => id}) do
    case GiTF.Quests.kill(id) do
      :ok -> json(conn, %{data: %{id: id, status: "killed"}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def close_quest(conn, %{"id" => id}) do
    case GiTF.Quests.close(id) do
      {:ok, quest} -> json(conn, %{data: serialize_quest(quest)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def start_quest(conn, %{"id" => id}) do
    case GiTF.Major.Orchestrator.start_quest(id) do
      {:ok, phase} -> json(conn, %{data: %{quest_id: id, phase: phase}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def plan_quest(conn, %{"id" => id}) do
    case GiTF.Major.Planner.generate_candidate_plans(id) do
      {:ok, plan} ->
        tasks = plan[:tasks] || plan.tasks || []

        # Read candidate count from quest record
        quest_record = GiTF.Store.get(:quests, id)
        candidates = if quest_record, do: Map.get(quest_record, :plan_candidates, []), else: []

        json(conn, %{
          data: %{
            quest_id: id,
            goal: plan[:goal],
            selected_strategy: plan[:strategy],
            candidates_count: length(candidates),
            tasks: Enum.map(tasks, fn t ->
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
    quest_record = GiTF.Store.get(:quests, id)

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
    quest_record = GiTF.Store.get(:quests, id)

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
            GiTF.Store.put(:quests, updated)

            tasks = candidate[:tasks] || candidate.tasks || []

            json(conn, %{
              data: %{
                quest_id: id,
                strategy: strategy,
                score: candidate[:score] || candidate.score,
                tasks: Enum.map(tasks, fn t ->
                  %{
                    title: t["title"] || t[:title],
                    description: t["description"] || t[:description],
                    target_files: t["target_files"] || t[:target_files] || [],
                    acceptance_criteria: t["acceptance_criteria"] || t[:acceptance_criteria] || [],
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
            quest: serialize_quest(status.quest),
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
        json(conn, %{data: %{text: GiTF.Report.format(report), quest_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_merge(conn, %{"id" => id}) do
    case GiTF.Merge.merge_quest(id) do
      {:ok, branch} ->
        json(conn, %{data: %{branch: branch, quest_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_spec_show(conn, %{"id" => quest_id, "phase" => phase}) do
    case GiTF.Specs.read(quest_id, phase) do
      {:ok, content} ->
        json(conn, %{data: %{content: content, quest_id: quest_id, phase: phase}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_spec_write(conn, %{"id" => quest_id, "phase" => phase} = params) do
    content = params["content"] || ""

    case GiTF.Specs.write(quest_id, phase, content) do
      {:ok, path} ->
        json(conn, %{data: %{path: path, quest_id: quest_id, phase: phase}})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def confirm_plan(conn, %{"id" => quest_id} = params) do
    specs = params["specs"] || []

    {:ok, jobs} = GiTF.Major.Planner.create_jobs_from_specs(quest_id, specs)
    GiTF.Quests.store_artifact(quest_id, "planning", specs)
    json(conn, %{data: %{quest_id: quest_id, jobs_created: length(jobs)}})
  end

  def reject_plan(conn, %{"id" => quest_id} = params) do
    feedback = params["feedback"]

    # Clear the draft plan
    quest_record = GiTF.Store.get(:quests, quest_id)

    if quest_record do
      updated = Map.delete(quest_record, :draft_plan)
      GiTF.Store.put(:quests, updated)

      if feedback do
        GiTF.Quests.store_artifact(quest_id, "plan_rejection", %{
          "feedback" => feedback,
          "rejected_at" => DateTime.utc_now()
        })
      end

      json(conn, %{data: %{rejected: true}})
    else
      error(conn, 404, :not_found)
    end
  end

  def revise_plan(conn, %{"id" => quest_id} = params) do
    feedback = params["feedback"] || ""

    case GiTF.Major.Planner.generate_llm_plan(quest_id, %{feedback: feedback}) do
      {:ok, plan} ->
        # Store as draft
        quest_record = GiTF.Store.get(:quests, quest_id)

        if quest_record do
          updated = Map.put(quest_record, :draft_plan, plan)
          GiTF.Store.put(:quests, updated)
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
      case params["quest_id"] do
        nil -> []
        id -> [quest_id: id]
      end

    jobs = GiTF.Jobs.list(opts)

    jobs =
      if params["all"] == "true" do
        jobs
      else
        case params["status"] do
          nil -> Enum.reject(jobs, &(&1.status in ["done", "failed"]))
          status -> Enum.filter(jobs, &(&1.status == status))
        end
      end

    json(conn, %{data: Enum.map(jobs, &serialize_job/1)})
  end

  def show_job(conn, %{"id" => id}) do
    case GiTF.Jobs.get(id) do
      {:ok, job} -> json(conn, %{data: serialize_job(job)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def reset_job(conn, %{"id" => id}) do
    case GiTF.Jobs.reset(id) do
      {:ok, job} -> json(conn, %{data: serialize_job(job)})
      {:error, :not_found} -> error(conn, 404, :not_found)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def kill_job(conn, %{"id" => id}) do
    case GiTF.Jobs.kill(id) do
      :ok -> json(conn, %{data: %{id: id, status: "killed"}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  # -- Bees --------------------------------------------------------------------

  def list_bees(conn, params) do
    ghosts = GiTF.Ghosts.list()

    ghosts =
      if params["all"] == "true" do
        ghosts
      else
        case params["status"] do
          nil -> Enum.reject(ghosts, &(&1.status in ["stopped", "crashed"]))
          status -> Enum.filter(ghosts, &(&1.status == status))
        end
      end

    json(conn, %{data: Enum.map(ghosts, &serialize_bee/1)})
  end

  def stop_ghost(conn, %{"id" => id}) do
    case GiTF.Ghosts.stop(id) do
      :ok -> json(conn, %{data: %{stopped: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def complete_bee(conn, %{"id" => ghost_id}) do
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} ->
        GiTF.Store.put(:ghosts, %{ghost | status: "stopped"})

        if ghost[:job_id] do
          # For phase jobs, extract artifact from the ghost's log before completing
          maybe_collect_phase_artifact(ghost_id, ghost[:job_id])

          GiTF.Jobs.complete(ghost[:job_id])
          GiTF.Jobs.unblock_dependents(ghost[:job_id])

          GiTF.Waggle.send(
            ghost_id,
            "major",
            "job_complete",
            "Job #{ghost[:job_id]} completed successfully"
          )
        end

        json(conn, %{data: %{completed: true}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)
    end
  end

  def fail_bee(conn, %{"id" => ghost_id} = params) do
    reason = params["reason"] || "unknown"

    case GiTF.Ghosts.get(ghost_id) do
      {:ok, ghost} ->
        GiTF.Store.put(:ghosts, %{ghost | status: "crashed"})

        if ghost[:job_id] do
          GiTF.Jobs.fail(ghost[:job_id])
          GiTF.Waggle.send(ghost_id, "major", "job_failed", "Job #{ghost[:job_id]} failed: #{reason}")
        end

        json(conn, %{data: %{failed: true}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)
    end
  end

  # -- Combs -------------------------------------------------------------------

  def add_comb(conn, params) do
    path = params["path"]
    opts_map = params["opts"] || %{}

    opts =
      opts_map
      |> Enum.reduce([], fn
        {"name", v}, acc -> [{:name, v} | acc]
        {"merge_strategy", v}, acc -> [{:merge_strategy, v} | acc]
        {"validation_command", v}, acc -> [{:validation_command, v} | acc]
        _, acc -> acc
      end)

    case GiTF.Comb.add(path, opts) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def list_combs(conn, _params) do
    combs = GiTF.Comb.list()
    json(conn, %{data: Enum.map(combs, &serialize_comb/1)})
  end

  def show_comb(conn, %{"id" => id}) do
    case GiTF.Comb.get(id) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def remove_comb(conn, %{"id" => id}) do
    case GiTF.Comb.remove(id) do
      {:ok, _comb} -> json(conn, %{data: %{deleted: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def use_comb(conn, %{"id" => id}) do
    case GiTF.Comb.set_current(id) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
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
        by_bee: summary.by_bee,
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

  defp maybe_collect_phase_artifact(ghost_id, job_id) do
    with {:ok, job} <- GiTF.Jobs.get(job_id),
         true <- Map.get(job, :phase_job, false),
         phase when is_binary(phase) <- Map.get(job, :phase) do
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
              GiTF.Quests.store_artifact(job.quest_id, phase, artifact)

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
      comb_id: q[:comb_id],
      current_phase: q[:current_phase],
      inserted_at: to_string(q[:inserted_at]),
      jobs:
        case q[:jobs] do
          nil -> []
          jobs -> Enum.map(jobs, &serialize_job/1)
        end
    }
  end

  defp serialize_job(j) do
    %{
      id: j.id,
      title: j.title,
      status: j.status,
      quest_id: j.quest_id,
      comb_id: j[:comb_id],
      ghost_id: j[:ghost_id],
      description: j[:description],
      inserted_at: to_string(j[:inserted_at])
    }
  end

  defp serialize_bee(b) do
    %{
      id: b.id,
      name: b.name,
      status: b.status,
      job_id: b[:job_id],
      context_percentage: b[:context_percentage]
    }
  end

  defp serialize_comb(c) do
    %{
      id: c.id,
      name: c.name,
      path: c[:path],
      repo_url: c[:repo_url],
      merge_strategy: c[:merge_strategy],
      validation_command: c[:validation_command]
    }
  end
end
