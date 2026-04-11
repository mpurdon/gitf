defmodule GiTF.Dashboard.MissionDetailLive do
  @moduledoc "Mission detail page with phase stepper, ops, and contextual actions."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(5)

  # Derive display phases from the orchestrator's canonical list,
  # adding "pending" and "completed" bookends, removing "awaiting_approval" (shown as sync)
  @phases ["pending"] ++
            (GiTF.Major.Orchestrator.phases() -- ["awaiting_approval"]) ++
            ["completed"]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:monitor")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        ops = GiTF.Ops.list(mission_id: id)

        {:ok,
         socket
         |> assign(:page_title, Map.get(mission, :name, "Mission"))
         |> assign(:current_path, "/dashboard/missions")
         |> assign(:mission, mission)
         |> assign(:ops, ops)
         |> assign(:op_filter, "active")
         |> assign(:show_full_goal, false)
         |> assign(:selected_phase, nil)
         |> assign(:artifact, nil)
         |> assign(:report, nil)
         |> assign(:report_loading, false)
         |> assign(:sectors, load_sectors())
         |> init_toasts()
         |> assign(:budget_info, %{budget: 0, spent: 0, remaining: 0, pct: 0.0})
         |> assign(:rollback_status, :unknown)
         |> assign(:priority, :normal)
         |> assign(:duration, nil)
         |> assign(:phase_durations, %{})
         |> compute_op_stats()
         |> reload()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Mission not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, reload(socket)}
  end

  def handle_info({:waggle_received, waggle}, socket) do
    {:noreply, socket |> maybe_apply_toast(waggle) |> reload()}
  end

  def handle_info({ref, {:report, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, report} ->
        formatted = GiTF.Report.format(report)
        {:noreply, assign(socket, report: formatted, report_loading: false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:report_loading, false)
         |> put_flash(:error, "Report failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start", _params, socket) do
    case GiTF.Major.Orchestrator.start_quest(socket.assigns.mission.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mission started.")
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("assign_sector", %{"sector_id" => sector_id}, socket) do
    mission = socket.assigns.mission

    case GiTF.Archive.get(:missions, mission.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mission not found")}

      record ->
        GiTF.Archive.put(:missions, Map.put(record, :sector_id, sector_id))
        {:noreply, socket |> put_flash(:info, "Sector assigned.") |> reload()}
    end
  end

  def handle_event("remove", _params, socket) do
    mission_id = socket.assigns.mission.id

    # Kill first to clean up all child artifacts (ops, ghosts, shells, deps)
    # then delete residual data (links, events, costs, phase transitions)
    case GiTF.Missions.kill(mission_id) do
      :ok ->
        cleanup_mission_artifacts(mission_id)

        {:noreply,
         socket
         |> put_flash(:info, "Mission and all associated data removed.")
         |> push_navigate(to: "/dashboard/missions")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: #{inspect(reason)}")}
    end
  end

  def handle_event("kill", _params, socket) do
    case GiTF.Missions.kill(socket.assigns.mission.id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Mission killed.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to kill: #{inspect(reason)}")}
    end
  end

  def handle_event("generate_report", _params, socket) do
    mission_id = socket.assigns.mission.id

    Task.async(fn ->
      {:report, GiTF.Report.generate(mission_id)}
    end)

    {:noreply, assign(socket, :report_loading, true)}
  end

  def handle_event("select_phase", %{"phase" => phase}, socket) do
    artifact = GiTF.Missions.get_artifact(socket.assigns.mission.id, phase)
    {:noreply, assign(socket, selected_phase: phase, artifact: artifact)}
  end

  def handle_event("reset_op", %{"id" => op_id}, socket) do
    case GiTF.Ops.reset(op_id, nil) do
      {:ok, _} ->
        {:noreply, reload(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  def handle_event("retry_all_failed", _params, socket) do
    failed_ops = Enum.filter(socket.assigns.ops, &(&1.status == "failed" && !&1[:phase_job]))

    retried =
      Enum.count(failed_ops, fn op ->
        case GiTF.Ops.reset(op.id, "batch retry from dashboard") do
          {:ok, _} -> true
          _ -> false
        end
      end)

    {:noreply,
     socket
     |> push_toast(:info, "Reset #{retried} failed op(s)")
     |> reload()}
  end

  def handle_event("filter_ops", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(:op_filter, filter) |> compute_op_stats()}
  end

  def handle_event("toggle_goal", _params, socket) do
    {:noreply, assign(socket, :show_full_goal, not socket.assigns.show_full_goal)}
  end

  def handle_event("toggle_op", %{"id" => op_id}, socket) do
    expanded = socket.assigns[:expanded_ops] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, op_id),
        do: MapSet.delete(expanded, op_id),
        else: MapSet.put(expanded, op_id)

    {:noreply, assign(socket, :expanded_ops, expanded)}
  end

  defp reload(socket) do
    id = socket.assigns.mission.id

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        # Budget utilization + forecast
        budget_info =
          try do
            budget = GiTF.Budget.budget_for(id)
            spent = GiTF.Budget.spent_for(id)
            remaining = GiTF.Budget.remaining(id)
            pct = if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0

            # Estimate: cost per completed op * remaining ops
            ops = GiTF.Ops.list(mission_id: id)
            done = Enum.count(ops, &(&1.status in ["done", "failed"]))
            pending = Enum.count(ops, &(&1.status in ["pending", "running", "assigned", "blocked"]))
            cost_per_op = if done > 0, do: Float.round(spent / done, 4), else: 0.0
            estimated_remaining = Float.round(cost_per_op * pending, 4)

            %{
              budget: budget,
              spent: spent,
              remaining: remaining,
              pct: pct,
              estimated_remaining: estimated_remaining,
              pending_ops: pending,
              done_ops: done
            }
          rescue
            _ -> %{budget: 0, spent: 0, remaining: 0, pct: 0.0, estimated_remaining: 0, pending_ops: 0, done_ops: 0}
          end

        # Rollback status
        rollback_status =
          try do
            GiTF.Rollback.revert_status(id)
          rescue
            _ -> :unknown
          end

        # Priority
        priority =
          try do
            GiTF.Priority.effective_priority(mission)
          rescue
            _ -> :normal
          end

        # Duration + phase timings
        duration = compute_duration(mission)

        phase_durations =
          try do
            GiTF.Missions.get_phase_transitions(id)
            |> compute_phase_durations()
          rescue
            _ -> %{}
          end

        socket
        |> assign(
          mission: mission,
          ops: GiTF.Ops.list(mission_id: id),
          sectors: load_sectors(),
          budget_info: budget_info,
          rollback_status: rollback_status,
          priority: priority,
          duration: duration,
          phase_durations: phase_durations
        )
        |> compute_op_stats()

      {:error, _} ->
        socket
    end
  end

  defp compute_op_stats(socket) do
    all_ops = socket.assigns.ops || []
    op_filter = socket.assigns[:op_filter] || "active"

    impl_ops = Enum.reject(all_ops, & &1[:phase_job])
    phase_ops = Enum.filter(all_ops, & &1[:phase_job])

    counts = %{
      done: Enum.count(impl_ops, &(Map.get(&1, :status) == "done")),
      running: Enum.count(impl_ops, &(Map.get(&1, :status) in ["running", "assigned"])),
      blocked: Enum.count(impl_ops, &(Map.get(&1, :status) == "blocked")),
      failed: Enum.count(impl_ops, &(Map.get(&1, :status) == "failed")),
      pending: Enum.count(impl_ops, &(Map.get(&1, :status) == "pending"))
    }

    visible_ops =
      case op_filter do
        "all" ->
          all_ops

        "active" ->
          Enum.reject(all_ops, &(Map.get(&1, :status) in ["done", "failed"] or &1[:phase_job]))

        "done" ->
          Enum.filter(all_ops, &(Map.get(&1, :status) == "done"))

        "failed" ->
          Enum.filter(all_ops, &(Map.get(&1, :status) == "failed"))

        "running" ->
          Enum.filter(all_ops, &(Map.get(&1, :status) in ["running", "assigned"]))

        "blocked" ->
          Enum.filter(all_ops, &(Map.get(&1, :status) == "blocked"))

        "pending" ->
          Enum.filter(all_ops, &(Map.get(&1, :status) == "pending"))

        "phase" ->
          phase_ops

        _ ->
          all_ops
      end

    assign(socket,
      visible_ops: visible_ops,
      counts: counts,
      total_ops: length(all_ops),
      impl_count: length(impl_ops),
      phase_op_count: length(phase_ops)
    )
  end

  defp cleanup_mission_artifacts(mission_id) do
    # Clean up links referencing this mission's ghosts/ops
    GiTF.Archive.all(:links)
    |> Enum.filter(fn l ->
      String.contains?(l.body || "", mission_id) or
        String.contains?(l.from || "", "ghost-")
    end)
    |> Enum.each(fn l -> GiTF.Archive.delete(:links, l.id) end)

    # Clean up events for this mission
    GiTF.EventStore.list(mission_id: mission_id, limit: 500)
    |> Enum.each(fn e -> GiTF.Archive.delete(:events, e.id) end)

    # Clean up phase transitions
    GiTF.Archive.filter(:mission_phase_transitions, fn t -> t.mission_id == mission_id end)
    |> Enum.each(fn t -> GiTF.Archive.delete(:mission_phase_transitions, t.id) end)

    # Clean up approval requests
    GiTF.Archive.filter(:approval_requests, fn r -> r.mission_id == mission_id end)
    |> Enum.each(fn r -> GiTF.Archive.delete(:approval_requests, r.id) end)

    # Clean up costs for ghosts that worked on this mission's ops
    GiTF.Archive.filter(:costs, fn c ->
      case GiTF.Archive.get(:ghosts, c.ghost_id) do
        %{op_id: op_id} when is_binary(op_id) ->
          case GiTF.Archive.get(:ops, op_id) do
            %{mission_id: ^mission_id} -> true
            _ -> false
          end

        _ ->
          false
      end
    end)
    |> Enum.each(fn c -> GiTF.Archive.delete(:costs, c.id) end)
  rescue
    _ -> :ok
  end

  defp compute_phase_durations(transitions) when is_list(transitions) do
    transitions
    |> Enum.sort_by(&(&1[:transitioned_at] || &1[:inserted_at]), DateTime)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [from, to], acc ->
      phase = from[:to_phase] || from[:from_phase]
      ts_from = from[:transitioned_at] || from[:inserted_at]
      ts_to = to[:transitioned_at] || to[:inserted_at]

      case {ts_from, ts_to} do
        {%DateTime{}, %DateTime{}} ->
          seconds = DateTime.diff(ts_to, ts_from, :second)
          Map.put(acc, phase, format_short_duration(seconds))

        _ ->
          acc
      end
    end)
  end

  defp compute_phase_durations(_), do: %{}

  defp format_short_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_short_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_short_duration(seconds), do: "#{div(seconds, 3600)}h#{rem(div(seconds, 60), 60)}m"

  defp compute_duration(mission) do
    started = mission[:inserted_at]

    case started do
      %DateTime{} ->
        ended = if mission[:status] in ["completed", "failed"], do: mission[:updated_at], else: DateTime.utc_now()

        case ended do
          %DateTime{} ->
            seconds = DateTime.diff(ended, started, :second)

            cond do
              seconds < 60 -> "#{seconds}s"
              seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
              true -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp load_sectors do
    try do
      GiTF.Sector.list()
    rescue
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:expanded_ops, MapSet.new())
      |> Map.put(:phases, @phases)

    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>

      <%!-- Header (full width) --%>
      <.breadcrumbs crumbs={[{"Missions", "/dashboard/missions"}, {Map.get(@mission, :name, "Mission"), nil}]} />
      <div style="margin-bottom:1.25rem">
          <h1 class="page-title" style="margin-bottom:0.25rem">
            {Map.get(@mission, :name, "Mission")}
          </h1>
          <div class={"goal-text #{if @show_full_goal, do: "goal-text-full"}"}>
            {Map.get(@mission, :goal, "")}
          </div>
          <%= if String.length(Map.get(@mission, :goal, "")) > 120 do %>
            <button phx-click="toggle_goal" class="goal-toggle">
              {if @show_full_goal, do: "Show less", else: "Show more"}
            </button>
          <% end %>
          <div style="margin-top:0.5rem; display:flex; gap:0.5rem; align-items:center; flex-wrap:wrap">
            <span class={"badge #{status_badge(Map.get(@mission, :status, "unknown"))}"}>
              {Map.get(@mission, :status, "unknown")}
            </span>
            <span class={"badge #{phase_badge(Map.get(@mission, :current_phase, "pending"))}"}>
              {Map.get(@mission, :current_phase, "pending")}
            </span>
            <span class={"badge #{if Map.get(@mission, :pipeline_mode) == "fast", do: "badge-yellow", else: "badge-purple"}"} style="font-size:0.65rem">
              {Map.get(@mission, :pipeline_mode, "pending") |> to_string() |> String.upcase()}
            </span>
            <%= if Map.get(@mission, :review_plan) do %>
              <span class="badge badge-purple" style="font-size:0.55rem">REVIEW</span>
            <% end %>
            <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">
              {short_id(@mission.id)}
            </span>
            <%= if @duration do %>
              <span style="font-size:0.75rem; color:#6b7280">&middot; {@duration}</span>
            <% end %>
          </div>
        </div>

      <%!-- Phase Stepper (full width) --%>
      <div class="panel">
        <div class="panel-title">Phase Pipeline</div>
        <div class="stepper">
          <%= for {phase, idx} <- Enum.with_index(@phases) do %>
            <%= if idx > 0 do %>
              <% prev = Enum.at(@phases, idx - 1) %>
              <div class={"step-line #{cond do
                phase_skipped?(@mission, prev) and phase_skipped?(@mission, phase) -> "step-line-skipped"
                phase_done?(@mission, prev) and not phase_skipped?(@mission, phase) -> "step-line-done"
                true -> ""
              end}"}></div>
            <% end %>
            <div
              class={"step #{phase_step_class(@mission, phase)}"}
              phx-click="select_phase"
              phx-value-phase={phase}
            >
              <div class="step-circle">
                <%= cond do %>
                  <% phase_skipped?(@mission, phase) -> %>
                    <span style="color:#4b5563">—</span>
                  <% phase_done?(@mission, phase) -> %>
                    <Heroicons.check mini class="w-4 h-4" />
                  <% true -> %>
                    <.phase_icon phase={phase} />
                <% end %>
              </div>
              <div class="step-label">{phase}</div>
              <%= if @phase_durations[phase] do %>
                <div style="font-size:0.6rem; color:#6b7280; margin-top:0.1rem">{@phase_durations[phase]}</div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Report (full width) --%>
      <%= if @report do %>
        <div class="panel">
          <div class="panel-title">Report</div>
          <div class="pre-block">{@report}</div>
        </div>
      <% end %>

      <%!-- ═══ TWO-COLUMN: OPS + SIDEBAR ═══ --%>
      <div class="mission-detail-layout">
      <div>
        <%!-- Ops Card List --%>
        <div class="panel">
          <div class="panel-title" style="margin-bottom:0.5rem">Ops</div>
          <div class="op-filters">
            <button phx-click="filter_ops" phx-value-filter="active" class={"op-filter-chip #{if @op_filter == "active", do: "op-filter-active"}"}>
              Active <span class="op-filter-count">{@counts.running + @counts.blocked + @counts.pending}</span>
            </button>
            <button :if={@counts.done > 0} phx-click="filter_ops" phx-value-filter="done" class={"op-filter-chip op-filter-green #{if @op_filter == "done", do: "op-filter-active"}"}>
              Done <span class="op-filter-count">{@counts.done}</span>
            </button>
            <button :if={@counts.running > 0} phx-click="filter_ops" phx-value-filter="running" class={"op-filter-chip op-filter-blue #{if @op_filter == "running", do: "op-filter-active"}"}>
              Running <span class="op-filter-count">{@counts.running}</span>
            </button>
            <button :if={@counts.blocked > 0} phx-click="filter_ops" phx-value-filter="blocked" class={"op-filter-chip op-filter-yellow #{if @op_filter == "blocked", do: "op-filter-active"}"}>
              Blocked <span class="op-filter-count">{@counts.blocked}</span>
            </button>
            <button :if={@counts.failed > 0} phx-click="filter_ops" phx-value-filter="failed" class={"op-filter-chip op-filter-red #{if @op_filter == "failed", do: "op-filter-active"}"}>
              Failed <span class="op-filter-count">{@counts.failed}</span>
            </button>
            <button :if={@phase_op_count > 0} phx-click="filter_ops" phx-value-filter="phase" class={"op-filter-chip op-filter-purple #{if @op_filter == "phase", do: "op-filter-active"}"}>
              Phase <span class="op-filter-count">{@phase_op_count}</span>
            </button>
            <button phx-click="filter_ops" phx-value-filter="all" class={"op-filter-chip #{if @op_filter == "all", do: "op-filter-active"}"}>
              All <span class="op-filter-count">{@total_ops}</span>
            </button>
            <%= if @counts.failed > 0 do %>
              <button phx-click="retry_all_failed" class="btn btn-orange" style="font-size:0.7rem; padding:0.2rem 0.5rem; margin-left:0.5rem" data-confirm={"Reset #{@counts.failed} failed op(s)?"}>
                Retry All Failed
              </button>
            <% end %>
          </div>
          <%= if @visible_ops == [] do %>
            <div class="empty">No ops created yet.</div>
          <% else %>
            <%= for op <- @visible_ops do %>
              <% op_status = Map.get(op, :status, "pending")
                 status_class = case op_status do
                   s when s in ["running", "assigned"] -> "op-card-running"
                   "failed" -> "op-card-failed"
                   "blocked" -> "op-card-blocked"
                   "done" -> "op-card-done"
                   _ -> ""
                 end %>
              <div
                class={"op-card #{status_class}"}
                phx-click="toggle_op"
                phx-value-id={op.id}
              >
                <%!-- Line 1: status icon + title --%>
                <div class="op-card-title">
                  <span class={"status-icon status-icon-#{status_icon_class(op_status)}"}>{status_icon(op_status)}</span>
                  <a href={"/dashboard/ops/#{op.id}"} style="color:#f0f6fc; font-size:0.9rem; flex:1" phx-click="toggle_op" phx-value-id={op.id}>
                    {Map.get(op, :title, "-")}
                  </a>
                  <%= if Map.get(op, :status) == "failed" do %>
                    <button phx-click="reset_op" phx-value-id={op.id} class="btn btn-grey" style="padding:0.15rem 0.4rem; font-size:0.7rem; flex-shrink:0">
                      Reset
                    </button>
                  <% end %>
                </div>
                <%!-- Line 2: badges + ghost + context --%>
                <div class="op-card-meta">
                  <span class={"badge #{status_badge(op_status)}"}>{op_status}</span>
                  <%= if Map.get(op, :verification_status) do %>
                    <span class={"badge #{verification_badge(op.verification_status)}"}>{op.verification_status}</span>
                  <% end %>
                  <% ghost_id = Map.get(op, :ghost_id) %>
                  <%= if ghost_id do %>
                    <% ghost_rec = GiTF.Archive.get(:ghosts, ghost_id) %>
                    <% {provider, _short, _tier} = parse_model(ghost_rec && ghost_rec[:assigned_model]) %>
                    <span class={"model-badge #{provider_class(provider)}"}>{ghost_badge_label(ghost_rec[:name] || short_id(ghost_id), ghost_rec[:assigned_model])}</span>
                  <% end %>
                  <% {ctx_pct, ctx_used, ctx_limit} = ghost_context_info(op) %>
                  <%= if ctx_pct > 0 do %>
                    <% bar_width = max(ctx_pct, 2) %>
                    <% label = if ctx_pct < 1, do: "<1%", else: "#{trunc(ctx_pct)}%" %>
                    <div style="display:flex; align-items:center; gap:0.3rem; min-width:5rem" title={"#{format_tokens_mb(ctx_used)} / #{format_tokens_mb(ctx_limit)}"}>
                      <div style="flex:1; height:5px; background:#1f2937; border-radius:3px; overflow:hidden">
                        <div style={"width:#{bar_width}%; height:100%; border-radius:3px; background:#{context_gauge_color(ctx_pct)}"}></div>
                      </div>
                      <span style={"font-size:0.65rem; font-family:monospace; color:#{context_gauge_color(ctx_pct)}"}>{label}</span>
                    </div>
                  <% end %>
                </div>
              </div>
              <%!-- Expanded detail --%>
              <%= if MapSet.member?(@expanded_ops, op.id) do %>
                <div class="plan-detail" style="border-bottom:1px solid #21262d">
                  <dl class="metadata-grid" style="margin-bottom:0.75rem">
                    <dt>Type</dt><dd>{Map.get(op, :type, "-")}</dd>
                    <dt>Complexity</dt><dd>{Map.get(op, :complexity, "-")}</dd>
                    <dt>Risk</dt><dd>{Map.get(op, :risk_level, "-")}</dd>
                    <dt>Retries</dt><dd>{Map.get(op, :retry_count, 0)}</dd>
                  </dl>
                  <%= if Map.get(op, :description) do %>
                    <div style="color:#8b949e; font-size:0.85rem; white-space:pre-wrap; line-height:1.5">{op.description}</div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- ═══ SIDEBAR ═══ --%>
      <div class="mission-sidebar">
        <%!-- Stats --%>
        <div class="panel" style="padding:0.85rem 1rem">
          <div class="sidebar-stat-row" style="cursor:pointer" phx-click="filter_ops" phx-value-filter="done">
            <span class="sidebar-stat-label">Done</span>
            <span class="sidebar-stat-value green">{@counts.done}</span>
          </div>
          <div class="sidebar-stat-row" style="cursor:pointer" phx-click="filter_ops" phx-value-filter="running">
            <span class="sidebar-stat-label">Running</span>
            <span class={"sidebar-stat-value #{if @counts.running > 0, do: "blue", else: ""}"}>{@counts.running}</span>
          </div>
          <div class="sidebar-stat-row" style="cursor:pointer" phx-click="filter_ops" phx-value-filter="blocked">
            <span class="sidebar-stat-label">Blocked</span>
            <span class={"sidebar-stat-value #{if @counts.blocked > 0, do: "yellow", else: ""}"}>{@counts.blocked}</span>
          </div>
          <div class="sidebar-stat-row" style="cursor:pointer" phx-click="filter_ops" phx-value-filter="failed">
            <span class="sidebar-stat-label">Failed</span>
            <span class={"sidebar-stat-value #{if @counts.failed > 0, do: "red", else: ""}"}>{@counts.failed}</span>
          </div>
          <div class="sidebar-stat-row" style="cursor:pointer" phx-click="filter_ops" phx-value-filter="pending">
            <span class="sidebar-stat-label">Pending</span>
            <span class="sidebar-stat-value">{@counts.pending}</span>
          </div>
          <div class="sidebar-stat-row" style="border-top:1px solid #30363d; margin-top:0.25rem; padding-top:0.5rem; cursor:pointer" phx-click="filter_ops" phx-value-filter="all">
            <span class="sidebar-stat-label" style="font-weight:600; color:#f0f6fc">Total</span>
            <span class="sidebar-stat-value">{@total_ops}</span>
          </div>
        </div>

        <%!-- Budget & Status --%>
        <div class="panel" style="padding:0.85rem 1rem">
          <div class="panel-title" style="font-size:0.85rem; margin-bottom:0.5rem; padding-bottom:0.4rem">Budget</div>
          <div style="display:flex; justify-content:space-between; font-size:0.8rem; margin-bottom:0.25rem">
            <span style="color:#8b949e">Spent</span>
            <span style="color:#3fb950">{format_cost(@budget_info.spent)} / {format_cost(@budget_info.budget)}</span>
          </div>
          <div style="height:6px; background:#21262d; border-radius:3px; overflow:hidden">
            <div style={"height:100%; border-radius:3px; background:#{cond do
              @budget_info.pct >= 90 -> "#f85149"
              @budget_info.pct >= 70 -> "#d29922"
              true -> "#3fb950"
            end}; width:#{min(@budget_info.pct, 100)}%"}></div>
          </div>
          <div style="display:flex; justify-content:space-between; margin-top:0.4rem; font-size:0.7rem; color:#6b7280">
            <span>{@budget_info.pct}% used</span>
            <span>{format_cost(@budget_info.remaining)} remaining</span>
          </div>
          <%= if @budget_info.estimated_remaining > 0 do %>
            <div style="margin-top:0.4rem; font-size:0.7rem; color:#8b949e; border-top:1px solid #21262d; padding-top:0.3rem">
              Est. {format_cost(@budget_info.estimated_remaining)} more
              <span style="color:#484f58">({@budget_info.pending_ops} ops @ {format_cost(if @budget_info.done_ops > 0, do: @budget_info.spent / @budget_info.done_ops, else: 0)}/op)</span>
            </div>
          <% end %>
          <div style="display:flex; gap:0.4rem; margin-top:0.5rem; align-items:center">
            <span class={"badge #{case @priority do
              :critical -> "badge-red"
              :high -> "badge-orange"
              :normal -> "badge-blue"
              :low -> "badge-grey"
              :background -> "badge-grey"
              _ -> "badge-grey"
            end}"} style="font-size:0.6rem">Priority: {@priority}</span>
            <%= if @rollback_status == :reverted do %>
              <span class="badge badge-red" style="font-size:0.6rem">Reverted</span>
            <% end %>
          </div>
        </div>

        <%!-- Quick Links --%>
        <div class="panel" style="padding:0.85rem 1rem">
          <div class="panel-title" style="font-size:0.85rem; margin-bottom:0.5rem; padding-bottom:0.4rem">Navigate</div>
          <div style="display:flex; flex-direction:column; gap:0.35rem">
            <a href={"/dashboard/timeline/#{@mission.id}"} style="color:#58a6ff; font-size:0.8rem">Event Timeline &rarr;</a>
            <a href={"/dashboard/progress"} style="color:#58a6ff; font-size:0.8rem">Ghost Progress &rarr;</a>
            <a href={"/dashboard/costs"} style="color:#58a6ff; font-size:0.8rem">Cost Details &rarr;</a>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="panel" style="padding:0.85rem 1rem">
          <div class="panel-title" style="font-size:0.85rem; margin-bottom:0.75rem; padding-bottom:0.4rem">Actions</div>
          <div class="sidebar-actions">
            <%!-- View buttons --%>
            <%= if has_artifacts?(@mission) do %>
              <a href={"/dashboard/missions/#{@mission.id}/plan"} class="btn btn-purple">View Plans</a>
            <% end %>
            <%= if has_design_artifacts?(@mission) do %>
              <a href={"/dashboard/missions/#{@mission.id}/design"} class="btn btn-purple">View Designs</a>
            <% end %>

            <%!-- Status-specific --%>
            <%= case Map.get(@mission, :status, "pending") do %>
              <% "pending" -> %>
                <button phx-click="start" class="btn btn-green">Start Mission</button>
              <% "active" -> %>
                <button phx-click="kill" class="btn btn-orange" data-confirm="Kill this mission?">Kill Mission</button>
              <% "completed" -> %>
                <button phx-click="generate_report" class="btn btn-blue" disabled={@report_loading}>
                  <%= if @report_loading do %>
                    <span class="loading-spinner" style="width:14px;height:14px;border-width:2px"></span>
                    Generating...
                  <% else %>
                    Generate Report
                  <% end %>
                </button>
              <% _ -> %>
            <% end %>

            <%!-- Diagnose --%>
            <%= if Map.get(@mission, :status) == "failed" || Enum.any?(@ops, &(Map.get(&1, :status) == "failed")) do %>
              <a href={"/dashboard/missions/#{@mission.id}/diagnostics"} class="btn btn-blue">Diagnose</a>
            <% end %>

            <%!-- Sector --%>
            <%= if is_nil(Map.get(@mission, :sector_id)) and @sectors != [] do %>
              <form phx-submit="assign_sector" style="display:flex; gap:0.5rem">
                <select name="sector_id" class="form-select" style="font-size:0.8rem; padding:0.3rem 0.5rem; flex:1">
                  <%= for sector <- @sectors do %>
                    <option value={sector.id}>{sector.name}</option>
                  <% end %>
                </select>
                <button type="submit" class="btn btn-blue" style="font-size:0.8rem; padding:0.3rem 0.6rem; flex-shrink:0">Assign</button>
              </form>
            <% end %>

            <%!-- Remove (always last, danger) --%>
            <button phx-click="remove" class="btn btn-red" data-confirm="Permanently remove this mission and all its data? This cannot be undone." style="margin-top:0.25rem">Remove</button>
          </div>
        </div>

        <%!-- Phase Artifact Viewer --%>
        <%= if @selected_phase do %>
          <div class="panel" style="padding:0.85rem 1rem">
            <div class="panel-title" style="font-size:0.85rem; margin-bottom:0.75rem; padding-bottom:0.4rem">Phase: {@selected_phase}</div>
            <%= if @artifact do %>
              <div class="pre-block" style="max-height:400px; overflow-y:auto; font-size:0.75rem">{inspect(@artifact, pretty: true, limit: :infinity)}</div>
            <% else %>
              <div class="empty" style="padding:1rem 0">No artifact stored.</div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>

    </.live_component>
    """
  end

  # Map orchestrator phases that aren't in the visual pipeline to their
  # nearest visual equivalent.  "awaiting_approval" sits between validation
  # and sync, so we display it as if the mission is at the "sync" step.
  defp phase_icon(%{phase: "pending"} = assigns), do: ~H"<Heroicons.clock mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "research"} = assigns),
    do: ~H"<Heroicons.magnifying_glass mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "requirements"} = assigns),
    do: ~H"<Heroicons.clipboard_document_list mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "design"} = assigns),
    do: ~H"<Heroicons.cube_transparent mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "review"} = assigns), do: ~H"<Heroicons.eye mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "planning"} = assigns), do: ~H"<Heroicons.map mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "implementation"} = assigns),
    do: ~H"<Heroicons.wrench_screwdriver mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "validation"} = assigns),
    do: ~H"<Heroicons.shield_check mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "sync"} = assigns),
    do: ~H"<Heroicons.arrow_path_rounded_square mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "simplify"} = assigns),
    do: ~H"<Heroicons.sparkles mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "scoring"} = assigns),
    do: ~H"<Heroicons.chart_bar mini class='w-4 h-4' />"

  defp phase_icon(%{phase: "completed"} = assigns),
    do: ~H"<Heroicons.flag mini class='w-4 h-4' />"

  defp phase_icon(assigns), do: ~H"<span>{@phase |> String.first() |> String.upcase()}</span>"

  defp normalise_phase("awaiting_approval"), do: "sync"
  defp normalise_phase(phase), do: phase

  # Phases that fast-path missions actually execute
  @fast_phases ~w(pending implementation validation sync scoring completed)

  defp phase_done?(mission, phase) do
    current = normalise_phase(Map.get(mission, :current_phase, "pending"))
    current_idx = Enum.find_index(@phases, &(&1 == current)) || 0
    phase_idx = Enum.find_index(@phases, &(&1 == phase)) || 0
    phase_idx < current_idx
  end

  defp phase_skipped?(mission, phase) do
    Map.get(mission, :pipeline_mode) == "fast" and phase not in @fast_phases
  end

  defp phase_step_class(mission, phase) do
    current = normalise_phase(Map.get(mission, :current_phase, "pending"))

    cond do
      phase == current -> "step-active"
      phase_skipped?(mission, phase) -> "step-skipped"
      phase_done?(mission, phase) -> "step-done"
      true -> "step-future"
    end
  end

  defp ghost_context_info(op) do
    case Map.get(op, :ghost_id) do
      nil ->
        {0.0, 0, 0}

      ghost_id ->
        case GiTF.Archive.get(:ghosts, ghost_id) do
          %{context_percentage: pct, context_tokens_used: used, context_tokens_limit: limit}
          when is_number(pct) ->
            {pct * 100, used || 0, limit || 0}

          %{context_percentage: pct} when is_number(pct) ->
            {pct * 100, 0, 0}

          _ ->
            {0.0, 0, 0}
        end
    end
  rescue
    _ -> {0.0, 0, 0}
  end

  # ~4 chars per token average, so tokens * 4 bytes ≈ context size
  defp format_tokens_mb(0), do: "-"

  defp format_tokens_mb(tokens) when is_number(tokens) do
    kb = tokens / 250

    if kb >= 1000 do
      "#{Float.round(kb / 1000, 1)}MB"
    else
      "#{Float.round(kb, 0) |> trunc()}KB"
    end
  end

  defp format_tokens_mb(_), do: "-"

  defp has_artifacts?(mission) do
    artifacts = Map.get(mission, :artifacts, %{})
    is_map(artifacts) and map_size(artifacts) > 0
  end

  defp has_design_artifacts?(mission) do
    artifacts = Map.get(mission, :artifacts, %{})

    is_map(artifacts) and
      Enum.any?(
        ["design_minimal", "design_normal", "design_complex", "design"],
        &Map.has_key?(artifacts, &1)
      )
  end

  defp context_gauge_color(pct) when pct >= 45, do: "#ef4444"
  defp context_gauge_color(pct) when pct >= 35, do: "#f59e0b"
  defp context_gauge_color(_pct), do: "#22c55e"
end
