defmodule GiTF.MCPServer.Handlers do
  @moduledoc "Tool execution handlers for the MCP server."

  require GiTF.Ghost.Status, as: GhostStatus

  def call("factory_status", _args) do
    missions = GiTF.Missions.list()
    active_missions = Enum.reject(missions, &(&1[:status] in ["completed", "closed", "killed"]))
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
          reason:
            get_in(event, [:data, :reason]) || get_in(event, [:data, :error]) ||
              get_in(event, [:data, :message]),
          op_id: get_in(event, [:metadata, :op_id]),
          mission_id: get_in(event, [:metadata, :mission_id])
        }
      end)

    result = %{
      missions: %{
        total: length(missions),
        active: length(active_missions),
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
      recent_failures: recent_failures
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
          nil -> Enum.reject(missions, &(&1[:status] in ["completed", "closed"]))
          _ -> missions
        end
      end

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

    {:ok, json_text(Enum.map(ghosts, &serialize_ghost/1))}
  end

  def call("list_sectors", _args) do
    sectors = GiTF.Sector.list()
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
      {:error, reason} -> {:error, inspect(reason)}
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
    case GiTF.Missions.get(id) do
      {:ok, _mission} ->
        limit = args["limit"] || 50
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
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def call("create_mission", _), do: {:error, "Missing required parameter: goal"}

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
          {:error, "Failed to start mission: #{inspect(reason)}"}
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
        {:error, reason} -> {:error, inspect(reason)}
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
            %{provider: provider.name, status: "error", error: inspect(reason)}
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
        {:ok, json_text(%{provider: name, status: "error", error: inspect(reason)})}
    end
  end

  def call("test_provider", _args) do
    {:error, "Provide either 'provider' name or 'all: true'"}
  end

  def call(tool_name, _args), do: {:error, "Unknown tool: #{tool_name}"}

  defp require_confirm(%{"confirm" => true}), do: :ok
  defp require_confirm(_), do: {:error, "Write operation requires confirm: true"}

  # -- Serializers -------------------------------------------------------------

  defp json_text(data) do
    Jason.encode!(data, pretty: true)
  end

  defp summarize_mission(m) do
    %{id: m[:id], name: m[:name], status: m[:status] || "pending", goal: m[:goal]}
  end

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

    detail
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
end
