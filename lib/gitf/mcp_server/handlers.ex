defmodule GiTF.MCPServer.Handlers do
  @moduledoc "Tool execution handlers for the MCP server."

  require Logger
  require GiTF.Ghost.Status, as: GhostStatus

  # Default stuck-mission threshold: 2 hours
  @default_stuck_threshold_ms 2 * 60 * 60 * 1000

  # Non-terminal mission phases — a mission stuck in these past the threshold
  # suggests orchestration or ghost-pool issues.
  @terminal_phases ~w(completed closed killed)

  def call("factory_status", _args) do
    missions = GiTF.Missions.list()
    # Everything an operator might still act on — paused missions included,
    # failed/closed/killed ones not. One shared definition of "done" instead
    # of this call's own list, which used to show a wall of failed missions.
    active_missions = Enum.reject(missions, &GiTF.Missions.finished?/1)
    ghosts = GiTF.Ghosts.list()
    active_ghosts = Enum.reject(ghosts, &GhostStatus.terminal?(&1.status))
    summary = GiTF.Costs.summary()
    health = GiTF.Observability.Health.check()

    recent_failures =
      (GiTF.EventStore.list(type: :ghost_failed, limit: 10) ++
         GiTF.EventStore.list(type: :merge_failed, limit: 5) ++
         GiTF.EventStore.list(type: :error, limit: 5))
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(15)
      |> Enum.map(fn event ->
        %{
          type: to_string(event.type),
          entity_id: event.entity_id,
          timestamp: to_string(event.timestamp),
          step: get_in(event, [:data, :step]),
          failure_class: get_in(event, [:data, :failure_class]),
          reason:
            get_in(event, [:data, :reason]) || get_in(event, [:data, :error]) ||
              get_in(event, [:data, :message]),
          op_id: get_in(event, [:metadata, :op_id]),
          mission_id: get_in(event, [:metadata, :mission_id])
        }
      end)

    stuck_count = count_stuck_missions(missions)

    # Failures by class over the last 7 days: separates "the provider was
    # down" from "the work was bad" — reliability is its own axis when
    # comparing models/providers, so it gets its own numbers. Old events
    # predate failure_class and report as unclassified.
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

    reliability =
      GiTF.EventStore.list(type: :ghost_failed, since: week_ago, limit: 1_000)
      |> Enum.frequencies_by(fn event ->
        to_string(get_in(event, [:data, :failure_class]) || "unclassified")
      end)

    result = %{
      missions: %{
        total: length(missions),
        active: length(active_missions),
        stuck: stuck_count,
        items: Enum.map(active_missions, &summarize_mission/1)
      },
      ghosts: %{
        total: length(ghosts),
        active: length(active_ghosts),
        items: Enum.map(active_ghosts, &summarize_ghost/1)
      },
      costs: %{
        total_usd: summary.total_cost,
        total_input_tokens: summary.total_input_tokens,
        total_output_tokens: summary.total_output_tokens
      },
      health: to_string(health.status),
      version: GiTF.version(),
      stuck_missions: stuck_count,
      recent_failures: recent_failures,
      reliability_7d: reliability
    }

    {:ok, json_text(result)}
  end

  def call("list_missions", args) do
    opts =
      case args["status"] do
        nil -> []
        status -> [status: status]
      end

    missions = GiTF.Missions.list(opts)

    missions =
      if args["all"] do
        missions
      else
        case args["status"] do
          nil ->
            Enum.reject(missions, fn mission ->
              # "completed" with async post-processing still running is NOT idle —
              # keep it in the default view until scoring finishes.
              mission[:status] in ["completed", "closed"] and
                mission[:post_processing_status] != "pending"
            end)

          _ ->
            missions
        end
      end

    missions = Enum.take(missions, cap_limit(args["limit"], 100, 500))
    {:ok, json_text(Enum.map(missions, &serialize_mission/1))}
  end

  def call("show_mission", %{"id" => id}) do
    case GiTF.Missions.get(id) do
      {:ok, mission} -> {:ok, json_text(serialize_mission(mission))}
      {:error, :not_found} -> {:error, "Mission not found: #{id}"}
    end
  end

  def call("show_mission", _), do: {:error, "Missing required parameter: id"}

  def call("list_ops", args) do
    opts =
      case args["mission_id"] do
        nil -> []
        id -> [mission_id: id]
      end

    ops = GiTF.Ops.list(opts)

    ops =
      if args["all"] do
        ops
      else
        case args["status"] do
          nil -> Enum.reject(ops, &(&1.status in ["done", "failed"]))
          status -> Enum.filter(ops, &(&1.status == status))
        end
      end

    ops = Enum.take(ops, cap_limit(args["limit"], 100, 500))
    {:ok, json_text(Enum.map(ops, &serialize_op/1))}
  end

  def call("show_op", %{"id" => id}) do
    case GiTF.Ops.get(id) do
      {:ok, op} -> {:ok, json_text(serialize_op_detail(op))}
      {:error, :not_found} -> {:error, "Op not found: #{id}"}
    end
  end

  def call("show_op", _), do: {:error, "Missing required parameter: id"}

  def call("list_ghosts", args) do
    ghosts = GiTF.Ghosts.list()

    ghosts =
      if args["all"] do
        ghosts
      else
        case args["status"] do
          nil -> Enum.reject(ghosts, &GhostStatus.terminal?(&1.status))
          status -> Enum.filter(ghosts, &(&1.status == status))
        end
      end

    ghosts = Enum.take(ghosts, cap_limit(args["limit"], 100, 500))
    {:ok, json_text(Enum.map(ghosts, &serialize_ghost/1))}
  end

  def call("list_sectors", args) do
    sectors = GiTF.Sector.list() |> Enum.take(cap_limit(args["limit"], 100, 500))
    {:ok, json_text(Enum.map(sectors, &serialize_sector/1))}
  end

  def call("costs_summary", _args) do
    summary = GiTF.Costs.summary()

    result = %{
      total_cost_usd: summary.total_cost,
      total_input_tokens: summary.total_input_tokens,
      total_output_tokens: summary.total_output_tokens,
      by_model: summary.by_model,
      by_ghost: summary.by_ghost,
      by_category: summary.by_category
    }

    {:ok, json_text(result)}
  end

  def call("ledger_stats", args) do
    mode = args["mode"]
    stats = GiTF.Ledger.stats(mode)
    {:ok, json_text(stats)}
  end

  def call("show_artifact", %{"mission_id" => mid, "phase" => phase} = args) do
    safe_handler("show_artifact", args, fn ->
      case GiTF.Missions.get_artifact(mid, phase) do
        nil ->
          {:ok, json_text(%{error: "No artifact found for phase '#{phase}'"})}

        artifact ->
          {truncated_artifact, truncated?} = truncate_artifact(artifact, 10_000)

          payload =
            if truncated? do
              wrap_truncated(truncated_artifact)
            else
              truncated_artifact
            end

          {:ok, json_text(payload)}
      end
    end)
  end

  def call("show_artifact", _), do: {:error, "Missing required parameters: mission_id, phase"}

  def call("ghost_output", %{"op_id" => op_id} = args) do
    safe_handler("ghost_output", args, fn ->
      case GiTF.Ops.get(op_id) do
        {:ok, op} ->
          {output_summary, out_trunc?} = truncate_string(op[:output_summary], 10_000)
          {changed_files_detail, det_trunc?} = truncate_any(op[:changed_files_detail], 10_000)

          base = %{
            op_id: op_id,
            output_summary: output_summary,
            files_changed: op[:files_changed],
            changed_files: op[:changed_files],
            changed_files_detail: changed_files_detail,
            branch: op[:branch],
            audit_result: op[:audit_result],
            verification_status: op[:verification_status]
          }

          payload =
            if out_trunc? or det_trunc? do
              Map.put(base, :truncated, true)
            else
              base
            end

          {:ok, json_text(payload)}

        {:error, _} ->
          {:error, "Op not found: #{op_id}"}
      end
    end)
  end

  def call("ghost_output", _), do: {:error, "Missing required parameter: op_id"}

  def call("mission_diagnosis", %{"id" => id} = args) do
    safe_handler("mission_diagnosis", args, fn ->
      case GiTF.Missions.get(id) do
        {:ok, mission} ->
          # Collect all phase artifacts
          phases = ~w(research requirements design planning validation sync scoring)
          artifacts = Map.new(phases, fn p ->
            {p, GiTF.Missions.get_artifact(id, p)}
          end) |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

          ops = Map.get(mission, :ops, [])

          # Collect impl op details (files, branch, output, fix lineage)
          impl_ops = ops
            |> Enum.reject(& &1[:phase_job])
            |> Enum.map(fn op ->
              %{
                id: op.id,
                title: op.title,
                status: op.status,
                files_changed: op[:files_changed],
                branch: op[:branch],
                fix_of: op[:fix_of],
                output_summary: op[:output_summary] && String.slice(op[:output_summary], 0, 500),
                audit_result: op[:audit_result],
                verification_status: op[:verification_status]
              }
            end)

          # Validation ops with their artifacts
          validation_ops = ops
            |> Enum.filter(& &1[:phase] == "validation")
            |> Enum.map(fn op ->
              %{
                id: op.id,
                status: op.status,
                output_summary: op[:output_summary] && String.slice(op[:output_summary], 0, 500)
              }
            end)

          # Phase transitions
          transitions = GiTF.Missions.get_phase_transitions(id)
            |> Enum.map(fn t ->
              %{from: t[:from_phase], to: t[:to_phase], reason: t[:reason], at: to_string(t[:inserted_at])}
            end)

          diagnosis = %{
            mission_id: id,
            name: mission[:name],
            status: mission.status,
            current_phase: mission[:current_phase],
            pipeline_mode: mission[:pipeline_mode],
            artifacts: artifacts,
            impl_ops: impl_ops,
            validation_ops: validation_ops,
            phase_transitions: transitions,
            total_ops: length(ops),
            fix_ops: length(Enum.filter(impl_ops, & &1[:fix_of]))
          }

          {:ok, json_text(diagnosis)}

        {:error, _} ->
          {:error, "Mission not found: #{id}"}
      end
    end)
  end

  def call("mission_diagnosis", _), do: {:error, "Missing required parameter: id"}

  def call("list_links", args) do
    opts =
      Enum.reduce(args, [], fn
        {"to", v}, acc when is_binary(v) -> [{:to, v} | acc]
        {"from", v}, acc when is_binary(v) -> [{:from, v} | acc]
        _, acc -> acc
      end)

    links = GiTF.Link.list(opts)
    limit = args["limit"] || 20
    links = Enum.take(links, limit)

    {:ok, json_text(Enum.map(links, &serialize_link/1))}
  end

  def call("mission_report", %{"id" => id}) do
    case GiTF.Report.generate(id) do
      {:ok, report} -> {:ok, GiTF.Report.format(report)}
      {:error, :not_found} -> {:error, "Mission not found: #{id}"}
      {:error, reason} -> {:error, log_and_sanitize("mission_report", reason)}
    end
  end

  def call("mission_report", _), do: {:error, "Missing required parameter: id"}

  def call("health_check", _args) do
    health = GiTF.Observability.Health.check()

    checks =
      Map.new(health.checks, fn {k, v} ->
        {to_string(k), to_string(v)}
      end)

    result = %{
      status: to_string(health.status),
      checks: checks,
      timestamp: DateTime.to_iso8601(health.timestamp)
    }

    {:ok, json_text(result)}
  end

  def call("mission_timeline", %{"id" => id} = args) do
    safe_handler("mission_timeline", args, fn ->
      case GiTF.Missions.get(id) do
        {:ok, _mission} ->
          limit = cap_limit(args["limit"], 50, 500)
          events = GiTF.EventStore.timeline(id)
          events = Enum.take(events, limit)

          formatted =
            Enum.map(events, fn event ->
              %{
                type: to_string(event.type),
                entity_id: event.entity_id,
                timestamp: to_string(event.timestamp),
                data: event.data,
                metadata: event.metadata
              }
            end)

          {:ok, json_text(formatted)}

        {:error, :not_found} ->
          {:error, "Mission not found: #{id}"}
      end
    end)
  end

  def call("mission_timeline", _), do: {:error, "Missing required parameter: id"}

  # -- Write operations (require confirm: true) -------------------------------

  def call("create_mission", %{"goal" => goal} = args) do
    with :ok <- require_confirm(args) do
      attrs = %{goal: goal}
      attrs = if args["sector_id"], do: Map.put(attrs, :sector_id, args["sector_id"]), else: attrs
      attrs = if args["name"], do: Map.put(attrs, :name, args["name"]), else: attrs
      attrs = if args["review_plan"], do: Map.put(attrs, :review_plan, true), else: attrs

      case GiTF.Missions.create(attrs) do
        {:ok, mission} -> {:ok, json_text(serialize_mission(mission))}
        {:error, reason} -> {:error, log_and_sanitize("create_mission", reason)}
      end
    end
  end

  def call("create_mission", _), do: {:error, "Missing required parameter: goal"}

  # -- Projects ----------------------------------------------------------------

  def call("create_project", %{"name" => _, "roadmap" => _} = args) do
    with :ok <- require_confirm(args) do
      attrs =
        args
        |> Map.take(["name", "brief", "roadmap", "sector_id"])
        |> Map.put("source", "api")

      case GiTF.Project.create(attrs) do
        {:ok, project} -> {:ok, json_text(serialize_project(project))}
        {:error, reason} -> {:error, log_and_sanitize("create_project", reason)}
      end
    end
  end

  def call("create_project", _), do: {:error, "Missing required parameters: name, roadmap"}

  def call("list_projects", args) do
    projects =
      case args["status"] do
        nil -> GiTF.Project.list()
        status -> Enum.filter(GiTF.Project.list(), &(&1.status == status))
      end

    {:ok, json_text(Enum.map(projects, &serialize_project/1))}
  end

  def call("show_project", %{"id" => id}) do
    case GiTF.Project.get(id) do
      nil -> {:error, "Project not found: #{id}"}
      project -> {:ok, json_text(serialize_project(project))}
    end
  end

  def call("approve_project", %{"id" => id} = args) do
    with :ok <- require_confirm(args),
         {:ok, _} <- resolve_project_sector(id, args),
         {:ok, project} <- GiTF.Project.activate(id) do
      {:ok, json_text(serialize_project(project))}
    else
      {:error, reason} -> {:error, log_and_sanitize("approve_project", reason)}
    end
  end

  def call("update_project_roadmap", %{"id" => id, "roadmap" => items} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Project.update_roadmap(id, items) do
        {:ok, project} -> {:ok, json_text(serialize_project(project))}
        {:error, reason} -> {:error, log_and_sanitize("update_project_roadmap", reason)}
      end
    end
  end

  def call("pause_project", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Project.pause(id, args["reason"]) do
        {:ok, project} -> {:ok, json_text(serialize_project(project))}
        {:error, reason} -> {:error, log_and_sanitize("pause_project", reason)}
      end
    end
  end

  def call("resume_project", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Project.resume(id) do
        {:ok, project} -> {:ok, json_text(serialize_project(project))}
        {:error, reason} -> {:error, log_and_sanitize("resume_project", reason)}
      end
    end
  end

  def call("start_mission", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      opts =
        cond do
          args["fast"] == true -> [force_fast_path: true]
          args["fast"] == false or args["full"] -> [force_full_pipeline: true]
          true -> []
        end

      case GiTF.Major.Orchestrator.start_quest(id, opts) do
        {:ok, phase} ->
          {:ok, json_text(%{id: id, status: "active", phase: phase})}

        {:error, reason} ->
          {:error, "Failed to start mission: #{log_and_sanitize("start_mission", reason)}"}
      end
    end
  end

  def call("start_mission", _), do: {:error, "Missing required parameter: id"}

  def call("kill_mission", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Missions.kill(id) do
        :ok -> {:ok, json_text(%{id: id, status: "killed"})}
        {:error, :not_found} -> {:error, "Mission not found: #{id}"}
      end
    end
  end

  def call("kill_mission", _), do: {:error, "Missing required parameter: id"}

  def call("close_mission", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Missions.close(id) do
        {:ok, mission} -> {:ok, json_text(serialize_mission(mission))}
        {:error, :not_found} -> {:error, "Mission not found: #{id}"}
      end
    end
  end

  def call("close_mission", _), do: {:error, "Missing required parameter: id"}

  def call("delete_mission", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Missions.delete(id) do
        :ok -> {:ok, json_text(%{id: id, deleted: true})}
        {:error, :not_found} -> {:error, "Mission not found: #{id}"}
      end
    end
  end

  def call("delete_mission", _), do: {:error, "Missing required parameter: id"}

  def call("reset_op", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Ops.reset(id) do
        {:ok, op} -> {:ok, json_text(serialize_op(op))}
        {:error, :not_found} -> {:error, "Op not found: #{id}"}
        {:error, reason} -> {:error, log_and_sanitize("reset_op", reason)}
      end
    end
  end

  def call("reset_op", _), do: {:error, "Missing required parameter: id"}

  def call("kill_op", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Ops.kill(id) do
        :ok -> {:ok, json_text(%{id: id, status: "killed"})}
        {:error, :not_found} -> {:error, "Op not found: #{id}"}
      end
    end
  end

  def call("kill_op", _), do: {:error, "Missing required parameter: id"}

  def call("stop_ghost", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Ghosts.stop(id) do
        :ok ->
          {:ok, json_text(%{id: id, status: GhostStatus.stopped()})}

        {:error, :not_found} ->
          # Worker process already gone — update the archive record directly
          case GiTF.Archive.get(:ghosts, id) do
            nil ->
              {:error, "Ghost not found: #{id}"}

            ghost ->
              GiTF.Archive.put(:ghosts, %{ghost | status: GhostStatus.stopped()})

              {:ok,
               json_text(%{
                 id: id,
                 status: GhostStatus.stopped(),
                 note: "Process already exited, record updated"
               })}
          end
      end
    end
  end

  def call("stop_ghost", _), do: {:error, "Missing required parameter: id"}

  def call(
        "send_link",
        %{"from" => from, "to" => to, "subject" => subject, "body" => body} = args
      ) do
    with :ok <- require_confirm(args) do
      {:ok, link} = GiTF.Link.send(from, to, subject, body)
      {:ok, json_text(serialize_link(link))}
    end
  end

  def call("send_link", _), do: {:error, "Missing required parameters: from, to, subject, body"}

  def call("test_provider", %{"all" => true}) do
    {configured, _} = GiTF.Runtime.ProviderManager.list_providers()

    results =
      Enum.map(configured, fn provider ->
        result = GiTF.Runtime.ProviderManager.test_connection(provider.name)

        case result do
          {:ok, latency} ->
            %{provider: provider.name, status: "ok", latency_ms: latency}

          {:error, %{message: msg, context: ctx}} ->
            %{provider: provider.name, status: "error", error: msg, details: ctx}

          {:error, reason} ->
            %{provider: provider.name, status: "error", error: log_and_sanitize("test_provider", reason)}
        end
      end)

    {:ok, json_text(results)}
  end

  def call("test_provider", %{"provider" => name}) do
    result = GiTF.Runtime.ProviderManager.test_connection(name)

    case result do
      {:ok, latency} ->
        {:ok, json_text(%{provider: name, status: "ok", latency_ms: latency})}

      {:error, %{message: msg, context: ctx}} ->
        {:ok, json_text(%{provider: name, status: "error", error: msg, details: ctx})}

      {:error, reason} ->
        {:ok, json_text(%{provider: name, status: "error", error: log_and_sanitize("test_provider", reason)})}
    end
  end

  def call("test_provider", _args) do
    {:error, "Provide either 'provider' name or 'all: true'"}
  end

  def call("circuit_status", _args) do
    {configured, _unconfigured} = GiTF.Runtime.ProviderManager.list_providers()

    providers =
      Enum.map(configured, fn p ->
        name = p.name
        key = GiTF.Runtime.ProviderCircuit.circuit_key(name)
        state = GiTF.Runtime.ProviderCircuit.provider_state(name)

        base = %{
          provider: name,
          state: to_string(state),
          failure_count: GiTF.CircuitBreaker.failure_count(key),
          last_failure: summarize_failure(GiTF.CircuitBreaker.last_failure_reason(key))
        }

        if state == :open do
          Map.merge(base, %{
            failure_mode: to_string(GiTF.Runtime.ProviderCircuit.failure_mode(name)),
            probe_interval_s: GiTF.Runtime.ProviderCircuit.probe_interval(name),
            seconds_until_probe: GiTF.Runtime.ProviderCircuit.seconds_until_probe(name),
            probe_due: GiTF.Runtime.ProviderCircuit.probe_due?(name)
          })
        else
          base
        end
      end)

    open = GiTF.Runtime.ProviderCircuit.open_providers()

    {:ok, json_text(%{open: open, providers: providers})}
  end

  def call("circuit_reset", %{"provider" => name} = args) do
    with :ok <- require_confirm(args) do
      :ok = GiTF.Runtime.ProviderCircuit.reset_provider(name)
      {:ok, json_text(%{provider: name, state: "closed"})}
    end
  end

  def call("circuit_reset", _), do: {:error, "Missing required parameter: provider"}

  def call("set_sync_strategy", %{"sector_id" => sector_id, "strategy" => strategy} = args)
      when strategy in ["auto_merge", "pr_branch", "manual"] do
    with :ok <- require_confirm(args) do
      case GiTF.Archive.update(:sectors, sector_id, fn s ->
             Map.put(s, :sync_strategy, strategy)
           end) do
        {:ok, _} ->
          {:ok, json_text(%{sector_id: sector_id, sync_strategy: strategy})}

        {:error, reason} ->
          {:error, "Failed to update sector: #{inspect(reason)}"}
      end
    end
  end

  def call("set_sync_strategy", %{"strategy" => strategy}) do
    {:error, "Invalid strategy '#{strategy}' — must be auto_merge, pr_branch, or manual"}
  end

  def call("set_sync_strategy", _), do: {:error, "Missing required parameters: sector_id, strategy, confirm"}

  # -- Skills ----------------------------------------------------------------

  def call("list_skills", args) do
    safe_handler("list_skills", args, fn ->
      include_archived = Map.get(args, "include_archived", false)
      scope_filter = Map.get(args, "scope")
      sector_filter = Map.get(args, "sector_id")

      all =
        GiTF.Skills.all()
        |> Enum.filter(fn s -> include_archived or s.status == :active end)
        |> Enum.filter(fn s ->
          cond do
            scope_filter == "global" -> s.scope == :global
            scope_filter == "sector" -> s.scope == :sector
            true -> true
          end
        end)
        |> Enum.filter(fn s ->
          if sector_filter, do: s.sector_id == sector_filter, else: true
        end)
        |> Enum.map(&summarize_skill/1)
        |> Enum.sort_by(& &1.applied_count, :desc)

      {:ok, json_text(%{count: length(all), skills: all})}
    end)
  end

  def call("show_skill", %{"id" => id}) do
    safe_handler("show_skill", %{"id" => id}, fn ->
      case GiTF.Skills.get(id) do
        nil ->
          {:error, "Skill not found: #{id}"}

        skill ->
          {:ok, json_text(detail_skill(skill))}
      end
    end)
  end

  def call("show_skill", _), do: {:error, "Missing required parameter: id"}

  def call("update_skill", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Skills.get(id) do
        nil ->
          {:error, "Skill not found: #{id}"}

        _ ->
          updates =
            %{}
            |> maybe_put(:name, Map.get(args, "name"))
            |> maybe_put(:description, Map.get(args, "description"))
            |> maybe_put(:body, Map.get(args, "body"))
            |> maybe_put(:status, parse_skill_status(Map.get(args, "status")))

          if updates == %{} do
            {:error, "No update fields provided (name, description, body, status)"}
          else
            case GiTF.Skills.update(id, fn s ->
                   # Clear embedding when body/description/name changes so
                   # retrieval re-embeds with the updated content.
                   needs_reembed =
                     Map.has_key?(updates, :name) or
                       Map.has_key?(updates, :description) or
                       Map.has_key?(updates, :body)

                   s
                   |> Map.merge(updates)
                   |> then(fn s ->
                     if needs_reembed,
                       do: Map.merge(s, %{embedding: nil, embedding_model: nil}),
                       else: s
                   end)
                 end) do
              {:ok, updated} -> {:ok, json_text(detail_skill(updated))}
              {:error, reason} -> {:error, "Update failed: #{inspect(reason)}"}
            end
          end
      end
    end
  end

  def call("update_skill", _), do: {:error, "Missing required parameters: id, confirm"}

  def call("delete_skill", %{"id" => id} = args) do
    with :ok <- require_confirm(args) do
      case GiTF.Skills.get(id) do
        nil ->
          {:error, "Skill not found: #{id}"}

        _ ->
          GiTF.Skills.delete(id)
          {:ok, json_text(%{id: id, deleted: true})}
      end
    end
  end

  def call("delete_skill", _), do: {:error, "Missing required parameters: id, confirm"}

  def call("skills_stats", args) do
    safe_handler("skills_stats", args, fn ->
      sector_filter = Map.get(args, "sector_id")

      pool =
        GiTF.Skills.all()
        |> Enum.filter(fn s ->
          if sector_filter,
            do: s.scope == :sector and s.sector_id == sector_filter,
            else: true
        end)

      active = Enum.filter(pool, &(&1.status == :active))

      by_scope = Enum.frequencies_by(active, & &1.scope)
      by_source = Enum.frequencies_by(active, & &1.source)

      top_applied =
        active
        |> Enum.sort_by(& &1.applied_count, :desc)
        |> Enum.take(10)
        |> Enum.map(&summarize_skill/1)

      low_utility =
        active
        |> Enum.filter(fn s ->
          total = s.success_count + s.failure_count
          total >= 10 and s.success_count / max(total, 1) < 0.3
        end)
        |> Enum.map(&summarize_skill/1)

      {:ok,
       json_text(%{
         total: length(pool),
         active: length(active),
         archived: length(pool) - length(active),
         by_scope: by_scope,
         by_source: by_source,
         top_applied: top_applied,
         low_utility_flagged: low_utility
       })}
    end)
  end

  # -- Outcomes --------------------------------------------------------------

  def call("list_outcomes", args) do
    safe_handler("list_outcomes", args, fn ->
      include_stopped = Map.get(args, "include_stopped", true)
      mission_filter = Map.get(args, "mission_id")
      category_filter = GiTF.Outcomes.parse_category(Map.get(args, "category"))

      {pool, category_applied?} =
        cond do
          is_binary(mission_filter) ->
            {GiTF.Archive.by_index(:mission_outcomes, :mission_id, mission_filter), false}

          not is_nil(category_filter) ->
            {GiTF.Archive.by_index(:mission_outcomes, :outcome_category, category_filter), true}

          true ->
            {GiTF.Outcomes.all(), false}
        end

      all =
        pool
        |> Enum.filter(fn o -> include_stopped or not o.tracking_stopped end)
        |> Enum.filter(fn o ->
          category_applied? or is_nil(category_filter) or o.outcome_category == category_filter
        end)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
        |> Enum.map(&summarize_outcome/1)

      {:ok, json_text(%{count: length(all), outcomes: all})}
    end)
  end

  def call("show_outcome", %{"id" => id}) do
    safe_handler("show_outcome", %{"id" => id}, fn ->
      case GiTF.Outcomes.get(id) do
        nil -> {:error, "Outcome not found: #{id}"}
        outcome -> {:ok, json_text(detail_outcome(outcome))}
      end
    end)
  end

  def call("show_outcome", _), do: {:error, "Missing required parameter: id"}

  def call("outcomes_stats", args) do
    safe_handler("outcomes_stats", args, fn ->
      sector_filter = Map.get(args, "sector_id")

      pool =
        case sector_filter do
          sid when is_binary(sid) -> GiTF.Archive.by_index(:mission_outcomes, :sector_id, sid)
          _ -> GiTF.Outcomes.all()
        end

      by_category = Enum.frequencies_by(pool, & &1.outcome_category)
      tracking = Enum.count(pool, &(not &1.tracking_stopped))

      terminal_cats = GiTF.Outcomes.terminal_categories()
      merged_clean = Map.get(by_category, :merged_clean, 0)
      terminal = Enum.sum(Enum.map(terminal_cats, &Map.get(by_category, &1, 0)))

      merge_rate = if terminal > 0, do: Float.round(merged_clean / terminal, 3), else: nil

      by_sector =
        pool
        |> Enum.group_by(&Map.get(&1, :sector_id))
        |> Enum.map(fn {sector_id, rows} ->
          t = Enum.count(rows, &(&1.outcome_category in terminal_cats))
          mc = Enum.count(rows, &(&1.outcome_category == :merged_clean))

          %{
            sector_id: sector_id,
            sample_count: t,
            merge_rate: if(t > 0, do: Float.round(mc / t, 3), else: nil)
          }
        end)

      calibration = GiTF.Outcomes.Alerts.calibration(sector_filter)

      {:ok,
       json_text(%{
         total: length(pool),
         tracking: tracking,
         by_category: by_category,
         merge_rate: merge_rate,
         by_sector: by_sector,
         calibration: calibration
       })}
    end)
  end

  # -- LSP -------------------------------------------------------------------

  def call("lsp_definition", args), do: lsp_call("lsp_definition", args, :locations, &lsp_def/1)
  def call("lsp_references", args), do: lsp_call("lsp_references", args, :references, &lsp_refs/1)
  def call("lsp_hover", args), do: lsp_call("lsp_hover", args, :hover, &lsp_hover/1)

  def call("lsp_diagnostics", %{"sector_id" => sid, "file_path" => fp} = args),
    do: lsp_simple("lsp_diagnostics", args, :diagnostics, fn -> GiTF.LSP.diagnostics(sid, fp) end)

  def call("lsp_diagnostics", _),
    do: {:error, "Missing required parameters: sector_id, file_path"}

  def call("lsp_document_symbol", %{"sector_id" => sid, "file_path" => fp} = args),
    do:
      lsp_simple("lsp_document_symbol", args, :symbols, fn ->
        GiTF.LSP.document_symbol(sid, fp)
      end)

  def call("lsp_document_symbol", _),
    do: {:error, "Missing required parameters: sector_id, file_path"}

  def call("lsp_workspace_symbol", %{"sector_id" => sid, "query" => query} = args),
    do:
      lsp_simple("lsp_workspace_symbol", args, :symbols, fn ->
        GiTF.LSP.workspace_symbol(sid, query)
      end)

  def call("lsp_workspace_symbol", _),
    do: {:error, "Missing required parameters: sector_id, query"}

  def call(
        "lsp_code_action",
        %{
          "sector_id" => sid,
          "file_path" => fp,
          "start_line" => sl,
          "start_character" => sc,
          "end_line" => el,
          "end_character" => ec
        } = args
      ) do
    range = %{start: %{line: sl, character: sc}, end: %{line: el, character: ec}}

    context =
      case Map.get(args, "only") do
        only when is_list(only) and only != [] -> %{only: only}
        _ -> %{}
      end

    lsp_simple("lsp_code_action", args, :actions, fn ->
      GiTF.LSP.code_action(sid, fp, range, context)
    end)
  end

  def call("lsp_code_action", _),
    do:
      {:error,
       "Missing required parameters: sector_id, file_path, start_line, start_character, end_line, end_character"}

  def call("lsp_apply_code_action", %{"edit" => edit} = args),
    do:
      lsp_simple("lsp_apply_code_action", args, :paths, fn ->
        GiTF.LSP.apply_workspace_edit(edit)
      end)

  def call("lsp_apply_code_action", _), do: {:error, "Missing required parameter: edit"}

  # -- Visual capture --------------------------------------------------------

  def call("capture_screenshot", %{"url" => url, "output_path" => output} = args) do
    safe_handler("capture_screenshot", args, fn ->
      opts =
        for {k, v} <- [full_page: Map.get(args, "full_page"), wait_ms: Map.get(args, "wait_ms")],
            not is_nil(v),
            do: {k, v}

      case GiTF.Visual.Capture.screenshot(url, output, opts) do
        {:ok, path} -> {:ok, json_text(%{ok: true, path: path})}
        {:error, reason} -> {:error, "Screenshot failed: #{inspect(reason)}"}
      end
    end)
  end

  def call("capture_screenshot", _),
    do: {:error, "Missing required parameters: url, output_path"}

  # -- Autonomy tiers --------------------------------------------------------

  def call("autonomy_tier", %{"sector_id" => sector_id}) do
    safe_handler("autonomy_tier", %{"sector_id" => sector_id}, fn ->
      detail = GiTF.Outcomes.Autonomy.tier_for(sector_id)
      override = GiTF.Outcomes.Autonomy.override_for(sector_id)
      effective = GiTF.Outcomes.Autonomy.effective_tier(sector_id)

      {:ok,
       json_text(%{
         sector_id: sector_id,
         derived_tier: detail.tier,
         rate: detail.rate,
         sample_count: detail.sample_count,
         reason: detail.reason,
         operator_override: override,
         effective_tier: effective
       })}
    end)
  end

  def call("autonomy_tier", _), do: {:error, "Missing required parameter: sector_id"}

  def call("set_autonomy_tier", %{"sector_id" => sector_id, "tier" => tier_str} = args) do
    with :ok <- require_confirm(args),
         {:ok, tier} <- parse_autonomy_tier(tier_str) do
      case GiTF.Archive.update(:sectors, sector_id, &Map.put(&1, :autonomy_level, tier)) do
        {:ok, _updated} -> {:ok, json_text(%{sector_id: sector_id, autonomy_level: tier})}
        {:error, :not_found} -> {:error, "Sector not found: #{sector_id}"}
        {:error, reason} -> {:error, "Update failed: #{inspect(reason)}"}
      end
    end
  end

  def call("set_autonomy_tier", _),
    do: {:error, "Missing required parameters: sector_id, tier, confirm"}

  # -- Knowledge --------------------------------------------------------------

  def call("knowledge_get", %{"slug" => slug} = args) do
    sector_id = Map.get(args, "sector_id")

    case GiTF.Knowledge.Page.get(sector_id, slug) do
      nil ->
        {:error, "Page not found: #{slug}"}

      page ->
        body =
          case GiTF.Knowledge.Page.read_body(sector_id, slug) do
            {:ok, body, _} -> body
            _ -> ""
          end

        {:ok,
         json_text(%{
           slug: page.slug,
           sector_id: page.sector_id,
           title: page.title,
           tags: page.tags,
           links_out: page.links_out,
           links_in: page.links_in,
           file_path: page.file_path,
           body: body
         })}
    end
  end

  def call("knowledge_get", _), do: {:error, "Missing required parameter: slug"}

  def call("knowledge_search", %{"query" => query} = args) do
    sector_id = Map.get(args, "sector_id")
    top_k = Map.get(args, "top_k", 5)
    min_sim = Map.get(args, "min_similarity", 0.4)

    case GiTF.Knowledge.Retrieval.search(sector_id, query,
           top_k: top_k,
           min_similarity: min_sim
         ) do
      {:ok, results} ->
        out =
          Enum.map(results, fn {score, p} ->
            %{
              slug: p.slug,
              title: p.title,
              sector_id: p.sector_id,
              score: score,
              tags: p.tags
            }
          end)

        {:ok, json_text(%{results: out})}
    end
  end

  def call("knowledge_search", _), do: {:error, "Missing required parameter: query"}

  def call("knowledge_links", %{"slug" => slug} = args) do
    sector_id = Map.get(args, "sector_id")

    direction =
      case Map.get(args, "direction", "both") do
        "out" -> :out
        "in" -> :in
        _ -> :both
      end

    pages = GiTF.Knowledge.Retrieval.links(sector_id, slug, direction: direction)

    out =
      Enum.map(pages, fn p ->
        %{slug: p.slug, title: p.title, sector_id: p.sector_id, tags: p.tags}
      end)

    {:ok, json_text(%{slug: slug, direction: direction, pages: out})}
  end

  def call("knowledge_links", _), do: {:error, "Missing required parameter: slug"}

  def call("knowledge_index", %{"name" => name} = args) do
    sector_id = Map.get(args, "sector_id")

    case GiTF.Knowledge.Index.get(sector_id, name) do
      nil ->
        {:error, "Index not found: #{name}"}

      idx ->
        {:ok,
         json_text(%{
           name: idx.name,
           sector_id: idx.sector_id,
           kind: idx.kind,
           position: idx.position,
           entries: idx.entries
         })}
    end
  end

  def call("knowledge_index", _), do: {:error, "Missing required parameter: name"}

  def call("knowledge_ingest_url", %{"url" => url} = args) do
    safe_handler("knowledge_ingest_url", args, fn ->
      sector_id = Map.get(args, "sector_id")

      opts =
        [
          depth: Map.get(args, "depth"),
          slug: Map.get(args, "slug"),
          title: Map.get(args, "title"),
          dry_run: Map.get(args, "dry_run")
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      report = GiTF.Knowledge.Ingest.URL.ingest(url, sector_id, opts)

      {:ok,
       json_text(%{
         ingested: Enum.map(report.ingested, fn {u, slug} -> %{url: u, slug: slug} end),
         skipped:
           Enum.map(report.skipped, fn {u, reason} ->
             %{url: to_string(u), reason: inspect(reason)}
           end),
         errors:
           Enum.map(report.errors, fn {u, reason} ->
             %{url: to_string(u), reason: inspect(reason)}
           end)
       })}
    end)
  end

  def call("knowledge_ingest_url", _), do: {:error, "Missing required parameter: url"}

  def call(tool_name, _args), do: {:error, "Unknown tool: #{tool_name}"}

  defp parse_autonomy_tier("trusted"), do: {:ok, :trusted}
  defp parse_autonomy_tier("normal"), do: {:ok, :normal}
  defp parse_autonomy_tier("require_approval"), do: {:ok, :require_approval}
  defp parse_autonomy_tier(other), do: {:error, "Invalid tier: #{inspect(other)}"}

  # -- Outcomes helpers -------------------------------------------------------

  defp summarize_outcome(o) do
    %{
      id: o.id,
      mission_id: o.mission_id,
      sector_id: Map.get(o, :sector_id),
      pr_url: o.pr_url,
      pr_state: o.pr_state,
      outcome_category: o.outcome_category,
      changes_requested_count: o.changes_requested_count,
      revert_detected: o.revert_detected,
      tracking_stopped: o.tracking_stopped,
      stopped_reason: o.stopped_reason,
      poll_count: o.poll_count,
      first_tracked_at: o.first_tracked_at,
      last_polled_at: o.last_polled_at,
      next_poll_at: o.next_poll_at,
      updated_at: o.updated_at
    }
  end

  defp detail_outcome(o) do
    Map.merge(summarize_outcome(o), %{
      reviews: o.reviews,
      pr_merged_at: o.pr_merged_at,
      pr_closed_at: o.pr_closed_at
    })
  end

  # -- Skills helpers ----------------------------------------------------------

  defp summarize_skill(skill) do
    %{
      id: skill.id,
      name: skill.name,
      description: skill.description,
      scope: skill.scope,
      sector_id: skill.sector_id,
      source: skill.source,
      status: skill.status,
      applied_count: skill.applied_count,
      success_count: skill.success_count,
      failure_count: skill.failure_count,
      updated_at: skill.updated_at
    }
  end

  defp detail_skill(skill) do
    Map.merge(summarize_skill(skill), %{body: skill.body})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_skill_status("active"), do: :active
  defp parse_skill_status("archived"), do: :archived
  defp parse_skill_status(nil), do: nil
  defp parse_skill_status(_), do: nil

  defp require_confirm(%{"confirm" => true}), do: :ok
  defp require_confirm(_), do: {:error, "Write operation requires confirm: true"}

  defp resolve_project_sector(id, %{"create_sector" => name}) when is_binary(name) do
    with {:ok, sector} <- GiTF.Sector.create_new(name) do
      GiTF.Project.assign_sector(id, sector.id)
    end
  end

  defp resolve_project_sector(id, %{"sector_id" => sector_id}) when is_binary(sector_id) do
    GiTF.Project.assign_sector(id, sector_id)
  end

  defp resolve_project_sector(_id, _args), do: {:ok, :unchanged}

  defp serialize_project(p) do
    %{
      id: p.id,
      name: p.name,
      status: p.status,
      source: p.source,
      sector_id: p.sector_id,
      brief: p.brief,
      roadmap:
        Enum.map(p.roadmap, fn item ->
          Map.take(item, [:id, :title, :goal, :depends_on, :status, :mission_id, :workflow_id])
        end),
      paused_reason: p[:paused_reason]
    }
  end

  # Wraps a read-handler body in try/rescue so an unexpected crash is logged
  # with handler name + args and returned as a structured error that does not
  # leak stacktraces or struct internals to the MCP client.
  defp safe_handler(name, args, fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      e ->
        Logger.error(
          "MCP handler #{name} crashed: #{Exception.message(e)} args=#{inspect(args, limit: 50, printable_limit: 500)}"
        )

        {:error,
         json_text(%{
           kind: "internal_error",
           handler: name,
           message: Exception.message(e)
         })}
    end
  end

  # Sanitizes an error term into a short client-facing string. Known atoms get
  # human-readable messages; unknown shapes collapse to "internal error". The
  # original term is logged separately so operators can still debug.
  defp sanitize_error(:not_found), do: "not found"
  defp sanitize_error(:invalid_transition), do: "invalid state transition"
  defp sanitize_error(:locked), do: "resource locked, try again"
  defp sanitize_error(:timeout), do: "operation timed out"
  defp sanitize_error(:max_retries_exceeded), do: "max retries exceeded"
  defp sanitize_error(:budget_exceeded), do: "budget exceeded"
  defp sanitize_error(atom) when is_atom(atom), do: to_string(atom)
  defp sanitize_error(bin) when is_binary(bin), do: bin
  defp sanitize_error({atom, _}) when is_atom(atom), do: sanitize_error(atom)
  defp sanitize_error(_), do: "internal error"

  defp log_and_sanitize(handler, reason) do
    Logger.warning("MCP handler #{handler} returned error: #{inspect(reason, limit: 50)}")
    sanitize_error(reason)
  end

  # Counts missions whose current_phase is non-terminal and whose updated_at is
  # older than the configured threshold. Used by factory_status to surface
  # orchestration stalls at a glance.
  defp count_stuck_missions(missions) do
    threshold_ms =
      case Application.get_env(:gitf, :timeouts) do
        nil -> @default_stuck_threshold_ms
        kw -> Keyword.get(kw, :stuck_mission_threshold_ms, @default_stuck_threshold_ms)
      end

    now = DateTime.utc_now()

    Enum.count(missions, fn m ->
      phase = m[:current_phase]
      updated_at = m[:updated_at] || m[:inserted_at]

      cond do
        phase in [nil | @terminal_phases] -> false
        is_nil(updated_at) -> false
        true ->
          case DateTime.diff(now, updated_at, :millisecond) do
            diff when diff >= threshold_ms -> true
            _ -> false
          end
      end
    end)
  rescue
    _ -> 0
  end

  # -- Serializers -------------------------------------------------------------

  defp json_text(data) do
    Jason.encode!(data, pretty: true)
  end

  defp summarize_mission(m) do
    %{id: m[:id], name: m[:name], status: m[:status] || "pending", goal: m[:goal]}
  end

  defp summarize_failure(nil), do: nil
  defp summarize_failure(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp summarize_failure(reason), do: reason |> inspect(limit: 10, printable_limit: 300)

  defp summarize_ghost(g) do
    %{id: g.id, name: g.name, status: g.status, op_id: g[:op_id]}
  end

  defp serialize_mission(m) do
    ops =
      case m[:ops] do
        nil -> GiTF.Ops.list(mission_id: m[:id])
        ops -> ops
      end

    %{
      id: m[:id],
      name: m[:name],
      status: m[:status] || "pending",
      goal: m[:goal],
      sector_id: m[:sector_id],
      current_phase: m[:current_phase],
      pipeline_mode: m[:pipeline_mode],
      post_processing_status: m[:post_processing_status],
      issue_ref: m[:issue_ref],
      cost_cap_usd: m[:cost_cap_usd],
      inserted_at: to_string(m[:inserted_at]),
      ops: Enum.map(ops, &serialize_op/1)
    }
  end

  # Compact op summary for mission listings — omits the full description
  # (which can be thousands of chars of prompt text). Use show_op for full details.
  defp serialize_op(j) do
    %{
      id: j.id,
      title: j.title,
      status: j.status,
      phase: j[:phase],
      mission_id: j.mission_id,
      sector_id: j[:sector_id],
      ghost_id: j[:ghost_id],
      inserted_at: to_string(j[:inserted_at])
    }
  end

  defp serialize_ghost(g) do
    base = %{
      id: g.id,
      name: g.name,
      status: g.status,
      op_id: g[:op_id],
      context_percentage: g[:context_percentage],
      assigned_model: g[:assigned_model],
      shell_path: g[:shell_path],
      inserted_at: to_string(g[:inserted_at])
    }

    # Include last progress if available
    progress =
      try do
        GiTF.Progress.get(g.id)
      rescue
        _ -> nil
      end

    if progress, do: Map.put(base, :last_progress, progress), else: base
  end

  defp serialize_op_detail(j) do
    base = serialize_op(j)

    detail =
      Map.merge(base, %{
        retry_count: j[:retry_count] || 0,
        risk_level: j[:risk_level],
        verification_status: j[:verification_status],
        phase_job: j[:phase_job] || false,
        phase: j[:phase],
        assigned_model: j[:assigned_model],
        recommended_model: j[:recommended_model],
        files_changed: j[:files_changed],
        changed_files: j[:changed_files],
        acceptance_criteria: j[:acceptance_criteria],
        skip_verification: j[:skip_verification] || false,
        depends_on: j[:depends_on] || []
      })

    # Include ghost status if assigned
    ghost_info =
      case j[:ghost_id] do
        nil ->
          nil

        ghost_id ->
          case GiTF.Archive.get(:ghosts, ghost_id) do
            nil -> %{id: ghost_id, status: "unknown"}
            g -> %{id: g.id, name: g.name, status: g.status, assigned_model: g[:assigned_model]}
          end
      end

    # Include recent events for this op
    recent_events =
      GiTF.EventStore.list(op_id: j.id, limit: 10)
      |> Enum.map(fn event ->
        %{
          type: to_string(event.type),
          timestamp: to_string(event.timestamp),
          data: event.data
        }
      end)

    # Include output summary, branch info, audit result, fix lineage
    extra = %{
      output_summary: j[:output_summary],
      branch: j[:branch],
      shell_id: j[:shell_id],
      audit_result: j[:audit_result],
      fix_of: j[:fix_of],
      fix_context: j[:fix_context],
      changed_files_detail: j[:changed_files_detail]
    }

    detail
    |> Map.merge(extra)
    |> Map.put(:ghost, ghost_info)
    |> Map.put(:recent_events, recent_events)
  end

  defp serialize_sector(s) do
    %{
      id: s.id,
      name: s.name,
      path: s[:path],
      repo_url: s[:repo_url],
      sync_strategy: s[:sync_strategy]
    }
  end

  # -- Limit + truncation helpers ---------------------------------------------

  defp cap_limit(nil, default, max), do: min(default, max)

  defp cap_limit(value, _default, max) when is_integer(value) and value > 0 do
    min(value, max)
  end

  defp cap_limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, max)
      _ -> min(default, max)
    end
  end

  defp cap_limit(_, default, max), do: min(default, max)

  defp truncate_string(nil, _), do: {nil, false}

  defp truncate_string(str, max) when is_binary(str) do
    if byte_size(str) > max do
      {binary_part(str, 0, max) <> "...[truncated]", true}
    else
      {str, false}
    end
  end

  defp truncate_string(other, _), do: {other, false}

  defp truncate_any(nil, _), do: {nil, false}

  defp truncate_any(value, max) when is_binary(value), do: truncate_string(value, max)

  defp truncate_any(value, max) do
    # Serialize non-string values and truncate their string form so a giant
    # map or list can't blow the response budget.
    encoded =
      case Jason.encode(value) do
        {:ok, s} -> s
        _ -> inspect(value, limit: :infinity, printable_limit: :infinity)
      end

    if byte_size(encoded) > max do
      {binary_part(encoded, 0, max) <> "...[truncated]", true}
    else
      {value, false}
    end
  end

  defp truncate_artifact(artifact, max) when is_binary(artifact) do
    truncate_string(artifact, max)
  end

  defp truncate_artifact(artifact, max) when is_map(artifact) do
    Enum.reduce(artifact, {%{}, false}, fn {k, v}, {acc, trunc?} ->
      {v2, t2} = truncate_any(v, max)
      {Map.put(acc, k, v2), trunc? or t2}
    end)
  end

  defp truncate_artifact(other, max), do: truncate_any(other, max)

  defp wrap_truncated(v) when is_map(v), do: Map.put(v, :truncated, true)
  defp wrap_truncated(v), do: %{truncated: true, data: v}

  defp serialize_link(l) do
    %{
      id: l.id,
      from: l.from,
      to: l.to,
      subject: l.subject,
      body: l.body,
      read: l[:read],
      inserted_at: to_string(l[:inserted_at])
    }
  end

  # -- LSP helpers -----------------------------------------------------------

  defp lsp_call(name, %{"sector_id" => sid, "file_path" => fp, "line" => l, "character" => c} = args, key, fun) do
    safe_handler(name, args, fn ->
      case fun.({sid, fp, l, c, args}) do
        {:ok, value} -> {:ok, json_text(Map.new([{:ok, true}, {key, value}]))}
        {:error, reason} -> {:error, "#{name} failed: #{inspect(reason)}"}
      end
    end)
  end

  defp lsp_call(_name, _args, _key, _fun),
    do: {:error, "Missing required parameters: sector_id, file_path, line, character"}

  # Same envelope as `lsp_call/4` but the args check + fn signature are
  # tool-specific (some tools need just sector + file, others need a
  # range, etc.), so each caller computes the LSP arguments inline and
  # passes a zero-arity closure that invokes the right `GiTF.LSP.*`
  # function. Centralises the `{:ok, _} | {:error, _} → json_text`
  # envelope across all 5 M3 tools.
  defp lsp_simple(name, args, key, fun) when is_function(fun, 0) do
    safe_handler(name, args, fn ->
      case fun.() do
        {:ok, value} -> {:ok, json_text(Map.new([{:ok, true}, {key, value}]))}
        {:error, reason} -> {:error, "#{name} failed: #{inspect(reason)}"}
      end
    end)
  end

  defp lsp_def({sid, fp, l, c, _}), do: GiTF.LSP.definition(sid, fp, l, c)

  defp lsp_refs({sid, fp, l, c, args}) do
    include = Map.get(args, "include_declaration", false) == true
    GiTF.LSP.references(sid, fp, l, c, include)
  end

  defp lsp_hover({sid, fp, l, c, _}), do: GiTF.LSP.hover(sid, fp, l, c)
end
