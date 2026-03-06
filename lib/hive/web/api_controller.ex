defmodule Hive.Web.ApiController do
  @moduledoc "REST API controller for remote CLI access."

  use Phoenix.Controller, formats: [:json]

  # -- Health ------------------------------------------------------------------

  def health(conn, _params) do
    json(conn, %{
      data: %{
        status: "ok",
        node: to_string(node()),
        uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
        version: Hive.version()
      }
    })
  end

  # -- Quests ------------------------------------------------------------------

  def create_quest(conn, params) do
    attrs =
      params
      |> Map.take(["goal", "comb_id"])
      |> atomize_keys()

    case Hive.Quests.create(attrs) do
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

    quests = Hive.Quests.list(opts)

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
          nil -> Enum.reject(quests, &(&1.status in ["completed", "closed"]))
          _ -> quests
        end
      end

    json(conn, %{data: Enum.map(quests, &serialize_quest/1)})
  end

  def show_quest(conn, %{"id" => id}) do
    case Hive.Quests.get(id) do
      {:ok, quest} -> json(conn, %{data: serialize_quest(quest)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def delete_quest(conn, %{"id" => id}) do
    case Hive.Quests.delete(id) do
      :ok -> json(conn, %{data: %{deleted: true}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def close_quest(conn, %{"id" => id}) do
    case Hive.Quests.close(id) do
      {:ok, quest} -> json(conn, %{data: serialize_quest(quest)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def start_quest(conn, %{"id" => id}) do
    case Hive.Queen.Orchestrator.start_quest(id) do
      {:ok, phase} -> json(conn, %{data: %{quest_id: id, phase: phase}})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def plan_quest(conn, %{"id" => id}) do
    case Hive.Queen.Planner.generate_candidate_plans(id) do
      {:ok, plan} ->
        tasks = plan[:tasks] || plan.tasks || []

        # Read candidate count from quest record
        quest_record = Hive.Store.get(:quests, id)
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
    quest_record = Hive.Store.get(:quests, id)

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
    quest_record = Hive.Store.get(:quests, id)

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
            Hive.Store.put(:quests, updated)

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
    case Hive.Queen.Orchestrator.get_quest_status(id) do
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
    case Hive.Report.generate(id) do
      {:ok, report} ->
        json(conn, %{data: %{text: Hive.Report.format(report), quest_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_merge(conn, %{"id" => id}) do
    case Hive.Merge.merge_quest(id) do
      {:ok, branch} ->
        json(conn, %{data: %{branch: branch, quest_id: id}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def quest_spec_show(conn, %{"id" => quest_id, "phase" => phase}) do
    case Hive.Specs.read(quest_id, phase) do
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

    case Hive.Specs.write(quest_id, phase, content) do
      {:ok, path} ->
        json(conn, %{data: %{path: path, quest_id: quest_id, phase: phase}})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def confirm_plan(conn, %{"id" => quest_id} = params) do
    specs = params["specs"] || []

    case Hive.Queen.Planner.create_jobs_from_specs(quest_id, specs) do
      {:ok, jobs} ->
        # Store as planning artifact
        Hive.Quests.store_artifact(quest_id, "planning", specs)
        json(conn, %{data: %{quest_id: quest_id, jobs_created: length(jobs)}})

      {:error, reason} ->
        error(conn, 422, reason)
    end
  end

  def reject_plan(conn, %{"id" => quest_id} = params) do
    feedback = params["feedback"]

    # Clear the draft plan
    quest_record = Hive.Store.get(:quests, quest_id)

    if quest_record do
      updated = Map.delete(quest_record, :draft_plan)
      Hive.Store.put(:quests, updated)

      if feedback do
        Hive.Quests.store_artifact(quest_id, "plan_rejection", %{
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

    case Hive.Queen.Planner.generate_llm_plan(quest_id, %{feedback: feedback}) do
      {:ok, plan} ->
        # Store as draft
        quest_record = Hive.Store.get(:quests, quest_id)

        if quest_record do
          updated = Map.put(quest_record, :draft_plan, plan)
          Hive.Store.put(:quests, updated)
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

    jobs = Hive.Jobs.list(opts)

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
    case Hive.Jobs.get(id) do
      {:ok, job} -> json(conn, %{data: serialize_job(job)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def reset_job(conn, %{"id" => id}) do
    case Hive.Jobs.reset(id) do
      {:ok, job} -> json(conn, %{data: serialize_job(job)})
      {:error, :not_found} -> error(conn, 404, :not_found)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- Bees --------------------------------------------------------------------

  def list_bees(conn, params) do
    bees = Hive.Bees.list()

    bees =
      if params["all"] == "true" do
        bees
      else
        case params["status"] do
          nil -> Enum.reject(bees, &(&1.status in ["stopped", "crashed"]))
          status -> Enum.filter(bees, &(&1.status == status))
        end
      end

    json(conn, %{data: Enum.map(bees, &serialize_bee/1)})
  end

  def stop_bee(conn, %{"id" => id}) do
    case Hive.Bees.stop(id) do
      :ok -> json(conn, %{data: %{stopped: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def complete_bee(conn, %{"id" => bee_id}) do
    case Hive.Bees.get(bee_id) do
      {:ok, bee} ->
        Hive.Store.put(:bees, %{bee | status: "stopped"})

        if bee.job_id do
          # For phase jobs, extract artifact from the bee's log before completing
          maybe_collect_phase_artifact(bee_id, bee.job_id)

          Hive.Jobs.complete(bee.job_id)
          Hive.Jobs.unblock_dependents(bee.job_id)

          Hive.Waggle.send(
            bee_id,
            "queen",
            "job_complete",
            "Job #{bee.job_id} completed successfully"
          )
        end

        json(conn, %{data: %{completed: true}})

      {:error, :not_found} ->
        error(conn, 404, :not_found)
    end
  end

  def fail_bee(conn, %{"id" => bee_id} = params) do
    reason = params["reason"] || "unknown"

    case Hive.Bees.get(bee_id) do
      {:ok, bee} ->
        Hive.Store.put(:bees, %{bee | status: "crashed"})

        if bee.job_id do
          Hive.Jobs.fail(bee.job_id)
          Hive.Waggle.send(bee_id, "queen", "job_failed", "Job #{bee.job_id} failed: #{reason}")
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

    case Hive.Comb.add(path, opts) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def list_combs(conn, _params) do
    combs = Hive.Comb.list()
    json(conn, %{data: Enum.map(combs, &serialize_comb/1)})
  end

  def show_comb(conn, %{"id" => id}) do
    case Hive.Comb.get(id) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def remove_comb(conn, %{"id" => id}) do
    case Hive.Comb.remove(id) do
      {:ok, _comb} -> json(conn, %{data: %{deleted: true}})
      {:error, :not_found} -> error(conn, 404, :not_found)
    end
  end

  def use_comb(conn, %{"id" => id}) do
    case Hive.Comb.set_current(id) do
      {:ok, comb} -> json(conn, %{data: serialize_comb(comb)})
      {:error, :not_found} -> error(conn, 404, :not_found)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # -- Costs -------------------------------------------------------------------

  def costs_summary(conn, _params) do
    summary = Hive.Costs.summary()

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
    bee_id = params["bee_id"]

    if is_nil(bee_id) do
      error(conn, 422, "bee_id is required")
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

      case Hive.Costs.record(bee_id, attrs) do
        {:ok, cost} ->
          json(conn, %{
            data: %{
              id: cost.id,
              bee_id: cost.bee_id,
              cost_usd: cost.cost_usd,
              input_tokens: cost.input_tokens,
              output_tokens: cost.output_tokens,
              model: cost.model,
              category: cost.category
            }
          })

        {:error, reason} ->
          error(conn, 422, reason)
      end
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

  defp maybe_collect_phase_artifact(bee_id, job_id) do
    with {:ok, job} <- Hive.Jobs.get(job_id),
         true <- Map.get(job, :phase_job, false),
         phase when is_binary(phase) <- Map.get(job, :phase) do
      # Read the bee's log file and extract the JSON artifact
      case find_bee_log(bee_id) do
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

          case Hive.Queen.PhaseCollector.collect(phase, log_content, events) do
            {:ok, artifact} ->
              Hive.Quests.store_artifact(job.quest_id, phase, artifact)

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

  defp find_bee_log(bee_id) do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        log_path = Path.join([hive_root, ".hive", "run", "#{bee_id}.log"])

        if File.exists?(log_path) do
          File.read(log_path)
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :no_hive_root}
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp serialize_quest(q) do
    %{
      id: q.id,
      name: q.name,
      status: q.status,
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
      bee_id: j[:bee_id],
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
