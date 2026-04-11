defmodule GiTF.Dashboard.OverviewLive do
  @moduledoc """
  Main dashboard overview showing key metrics at a glance.

  Displays active ghost count, mission count, total cost, and recent
  link_msg messages. Subscribes to PubSub for live updates when new
  links arrive.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  require GiTF.Ghost.Status, as: GhostStatus

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to all link_msg traffic for live updates
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "ops")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "ghosts")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "costs")

      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> init_toasts()
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info({:waggle_received, waggle}, socket) do
    {:noreply, socket |> maybe_apply_toast(waggle) |> assign_data()}
  end

  def handle_info({:op_updated, _op}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:ghost_updated, _ghost}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:cost_recorded, _cost}, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("toggle_dark_factory", _params, socket) do
    new_val = !socket.assigns.dark_factory
    case GiTF.Config.update_major_config(%{"dark_factory" => new_val}) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Dark Factory Mode #{if new_val, do: "ENABLED", else: "DISABLED"}")
         |> assign(:dark_factory, new_val)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update config: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("use_sector", %{"id" => sector_id}, socket) do
    case GiTF.Sector.set_current(sector_id) do
      {:ok, sector} ->
        {:noreply,
         socket
         |> put_flash(:info, "Switched to sector: #{sector.name || sector.id}")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("quick_run", %{"task" => %{"goal" => goal}}, socket) do
    goal = String.trim(goal)

    if goal == "" do
      {:noreply, put_flash(socket, :error, "Goal cannot be empty")}
    else
      sectors = GiTF.Sector.list()

      sector_id =
        case sectors do
          [s] -> s.id
          _ -> nil
        end

      attrs = %{goal: goal}
      attrs = if sector_id, do: Map.put(attrs, :sector_id, sector_id), else: attrs

      case GiTF.Missions.create(attrs) do
        {:ok, mission} ->
          case GiTF.Major.Orchestrator.start_quest(mission.id, force_fast_path: true) do
            {:ok, _phase} ->
              {:noreply,
               socket
               |> put_flash(:info, "Task started — ghost is working on it.")
               |> push_navigate(to: "/dashboard/missions/#{mission.id}")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    end
  end

  defp assign_data(socket) do
    ghosts = GiTF.Ghosts.list()
    missions = GiTF.Missions.list()
    cost_summary = GiTF.Costs.summary()
    recent_waggles = GiTF.Link.list(limit: 5)

    active_ghost_list = Enum.filter(ghosts, &GhostStatus.active?(Map.get(&1, :status)))
    active_ghosts = length(active_ghost_list)
    active_quests = Enum.count(missions, &(Map.get(&1, :status) == "active"))

    {avg_context, peak_context, high_context_bees} =
      case active_ghost_list do
        [] ->
          {0.0, 0.0, 0}

        active ->
          pcts = Enum.map(active, &(Map.get(&1, :context_percentage, 0.0) * 100))
          peaks = Enum.map(active, &(Map.get(&1, :context_peak_percentage, 0.0) * 100))
          avg = Enum.sum(pcts) / length(pcts)
          peak = Enum.max(peaks, fn -> 0.0 end)
          high = Enum.count(pcts, &(&1 > 40))
          {avg, peak, high}
      end

    # "Fuel remaining" = inverse of average usage (100% = full tank, 0% = empty)
    fuel_remaining = max(0.0, 100.0 - avg_context)

    # Audit stats
    ops = GiTF.Ops.list()
    verified_jobs = Enum.count(ops, &(Map.get(&1, :verification_status) == "passed"))
    failed_verification = Enum.count(ops, &(Map.get(&1, :verification_status) == "failed"))

    pending_verification =
      Enum.count(
        ops,
        &(Map.get(&1, :verification_status) == "pending" and Map.get(&1, :status) == "done")
      )

    # Quest phases
    research_quests = Enum.count(missions, &(Map.get(&1, :current_phase) == "research"))
    planning_quests = Enum.count(missions, &(Map.get(&1, :current_phase) == "planning"))

    implementation_quests =
      Enum.count(missions, &(Map.get(&1, :current_phase) == "implementation"))

    # Daily stats
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    completed_today =
      Enum.count(missions, fn m ->
        m.status == "completed" and
          m[:updated_at] != nil and
          DateTime.compare(m.updated_at, today_start) != :lt
      end)

    failed_today =
      Enum.count(missions, fn m ->
        m.status == "failed" and
          m[:updated_at] != nil and
          DateTime.compare(m.updated_at, today_start) != :lt
      end)

    ops_completed_today =
      Enum.count(ops, fn op ->
        op.status == "done" and
          op[:updated_at] != nil and
          DateTime.compare(op.updated_at, today_start) != :lt
      end)

    # Approvals & sectors
    pending_approvals =
      try do
        length(GiTF.Override.pending_approvals())
      rescue
        _ -> 0
      end

    sectors =
      try do
        GiTF.Sector.list()
      rescue
        _ -> []
      end

    sector_count = length(sectors)

    current_sector_id =
      case GiTF.Sector.current() do
        {:ok, s} -> s.id
        _ -> nil
      end

    recent_sectors =
      sectors
      |> Enum.sort_by(&(-safe_unix_ts(&1)))
      |> Enum.take(5)

    # Recent missions for the overview card (active first, then recent completed)
    # Enrich with budget + ghost count for the cards
    ghost_by_mission =
      ghosts
      |> Enum.filter(&GhostStatus.active?(Map.get(&1, :status)))
      |> Enum.reduce(%{}, fn ghost, acc ->
        case ghost[:op_id] do
          nil -> acc
          op_id ->
            case GiTF.Archive.get(:ops, op_id) do
              %{mission_id: mid} when not is_nil(mid) ->
                Map.update(acc, mid, 1, &(&1 + 1))
              _ -> acc
            end
        end
      end)

    recent_missions =
      missions
      |> Enum.sort_by(fn m ->
        active = if Map.get(m, :status) in ["active", "implementation", "research", "design", "planning", "review"], do: 0, else: 1
        {active, -safe_unix_ts(m)}
      end)
      |> Enum.take(8)
      |> Enum.map(fn m ->
        budget_pct =
          try do
            budget = GiTF.Budget.budget_for(m.id)
            spent = GiTF.Budget.spent_for(m.id)
            if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0
          rescue
            _ -> 0.0
          end

        Map.merge(m, %{
          ghost_count: Map.get(ghost_by_mission, m.id, 0),
          budget_pct: budget_pct
        })
      end)

    # Dark Factory status
    dark_factory = GiTF.Config.dark_factory?()

    health_status =
      try do
        GiTF.Observability.Health.check().status
      rescue
        _ -> :unknown
      end

    socket
    |> assign(:page_title, "Overview")
    |> assign(:current_path, "/")
    |> assign(:last_updated, DateTime.utc_now())
    |> assign(:dark_factory, dark_factory)
    |> assign(:ghost_count, length(ghosts))
    |> assign(:active_ghosts, active_ghosts)
    |> assign(:quest_count, length(missions))
    |> assign(:active_quests, active_quests)
    |> assign(:total_cost, cost_summary.total_cost)
    |> assign(:total_input_tokens, cost_summary.total_input_tokens)
    |> assign(:total_output_tokens, cost_summary.total_output_tokens)
    |> assign(:cost_by_model, cost_summary.by_model)
    |> assign(:recent_waggles, recent_waggles)
    |> assign(:active_processes, safe_active_count())
    |> assign(:avg_context, avg_context)
    |> assign(:peak_context, peak_context)
    |> assign(:fuel_remaining, fuel_remaining)
    |> assign(:high_context_bees, high_context_bees)
    |> assign(:active_ghost_list, active_ghost_list)
    |> assign(:verified_jobs, verified_jobs)
    |> assign(:failed_verification, failed_verification)
    |> assign(:pending_verification, pending_verification)
    |> assign(:research_quests, research_quests)
    |> assign(:planning_quests, planning_quests)
    |> assign(:implementation_quests, implementation_quests)
    |> assign(:pending_approvals, pending_approvals)
    |> assign(:sector_count, sector_count)
    |> assign(:recent_sectors, recent_sectors)
    |> assign(:current_sector_id, current_sector_id)
    |> assign(:recent_missions, recent_missions)
    |> assign(:health_status, health_status)
    |> assign(:completed_today, completed_today)
    |> assign(:failed_today, failed_today)
    |> assign(:ops_completed_today, ops_completed_today)
  end

  @mini_phases (GiTF.Major.Orchestrator.phases() -- ["awaiting_approval"]) ++ ["completed"]

  defp mini_phase_pipeline(assigns) do
    current = assigns.phase || "pending"
    phases = @mini_phases

    current_idx = Enum.find_index(phases, &(&1 == normalise_overview_phase(current))) || -1

    assigns = assign(assigns, :phases, phases)
    assigns = assign(assigns, :current_idx, current_idx)

    ~H"""
    <div style="display:flex; align-items:center; gap:0px">
      <%= for {phase, idx} <- Enum.with_index(@phases) do %>
        <%= if idx > 0 do %>
          <div style={"width:6px; height:1px; background:#{if idx <= @current_idx, do: "#22c55e", else: "#30363d"}"}></div>
        <% end %>
        <div
          title={phase}
          style={"width:6px; height:6px; border-radius:50%; background:#{cond do
            idx < @current_idx -> "#22c55e"
            idx == @current_idx -> "#3b82f6"
            true -> "#30363d"
          end}"}
        ></div>
      <% end %>
    </div>
    """
  end

  defp normalise_overview_phase("awaiting_approval"), do: "sync"
  defp normalise_overview_phase("pending"), do: "pending"
  defp normalise_overview_phase(phase), do: phase

  defp mission_status_badge("active"), do: "badge-blue"
  defp mission_status_badge("completed"), do: "badge-green"
  defp mission_status_badge("failed"), do: "badge-red"
  defp mission_status_badge("killed"), do: "badge-red"
  defp mission_status_badge("planning"), do: "badge-yellow"
  defp mission_status_badge(_), do: "badge-grey"

  defp safe_unix_ts(record) do
    ts = Map.get(record, :updated_at) || Map.get(record, :inserted_at)

    case ts do
      %DateTime{} -> DateTime.to_unix(ts)
      _ -> 0
    end
  end

  defp short_model_name(name) when is_binary(name) do
    name
    |> String.replace(~r"^(google|anthropic|bedrock|openai|amazon):", "")
    |> String.replace(~r"^(anthropic\.|amazon\.)", "")
    |> String.replace("gemini-", "")
    |> String.replace("claude-", "")
  end

  defp short_model_name(_), do: "unknown"

  defp model_bar_color(name) when is_binary(name) do
    cond do
      String.contains?(name, "pro") or String.contains?(name, "opus") -> "#a855f7"
      String.contains?(name, "flash") or String.contains?(name, "sonnet") -> "#3b82f6"
      String.contains?(name, "haiku") -> "#06b6d4"
      true -> "#6b7280"
    end
  end

  defp model_bar_color(_), do: "#6b7280"

  defp safe_active_count do
    GiTF.SectorSupervisor.active_count()
  rescue
    _ -> 0
  end

  # Icon component for link message subjects
  defp link_msg_icon(assigns) do
    ~H"""
    <span class="link-icon" style="display:inline-flex;vertical-align:middle;margin-right:6px;">
      <%= case @subject do %>
        <% "health_alert" -> %><Heroicons.exclamation_triangle mini class="w-4 h-4" style="color:#f59e0b;" />
        <% "job_complete" -> %><Heroicons.check_circle mini class="w-4 h-4" style="color:#22c55e;" />
        <% "job_failed" -> %><Heroicons.x_circle mini class="w-4 h-4" style="color:#ef4444;" />
        <% "job_merged" -> %><Heroicons.arrow_path_rounded_square mini class="w-4 h-4" style="color:#8b5cf6;" />
        <% "merge_failed" -> %><Heroicons.fire mini class="w-4 h-4" style="color:#ef4444;" />
        <% "quest_advance" -> %><Heroicons.forward mini class="w-4 h-4" style="color:#3b82f6;" />
        <% "scout_complete" -> %><Heroicons.magnifying_glass mini class="w-4 h-4" style="color:#06b6d4;" />
        <% "reimagine_job_created" -> %><Heroicons.arrow_path mini class="w-4 h-4" style="color:#f97316;" />
        <% "context_handoff" -> %><Heroicons.arrow_right_on_rectangle mini class="w-4 h-4" style="color:#8b5cf6;" />
        <% "human_approval" -> %><Heroicons.user mini class="w-4 h-4" style="color:#a855f7;" />
        <% "plan_approval_needed" -> %><Heroicons.clipboard_document_check mini class="w-4 h-4" style="color:#eab308;" />
        <% "pr_created" -> %><Heroicons.code_bracket mini class="w-4 h-4" style="color:#22d3ee;" />
        <% "start_mission" -> %><Heroicons.rocket_launch mini class="w-4 h-4" style="color:#10b981;" />
        <% _ -> %><Heroicons.chat_bubble_left mini class="w-4 h-4" style="color:#6b7280;" />
      <% end %>
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.5rem">
        <div style="display:flex; align-items:baseline; gap:0.75rem">
          <h1 class="page-title" style="margin-bottom:0">Dashboard Overview</h1>
          <a href="/dashboard/health" style={"display:inline-flex; align-items:center; gap:0.3rem; font-size:0.7rem; color:#{if @health_status == :healthy, do: "#3fb950", else: "#f85149"}; text-decoration:none"} title="System health">
            <span style={"width:6px; height:6px; border-radius:50%; background:#{if @health_status == :healthy, do: "#3fb950", else: "#f85149"}"}></span>
            {if @health_status == :healthy, do: "healthy", else: "degraded"}
          </a>
          <span style="font-size:0.7rem; color:#484f58" title="Auto-refreshes every 5s">
            &middot; updated {format_timestamp(@last_updated)}
          </span>
        </div>
        
        <div style="display:flex; align-items:center; gap:0.75rem; background:#1c2128; border:1px solid #30363d; padding:0.5rem 0.75rem; border-radius:6px">
          <div style="display:flex; flex-direction:column">
            <span style="font-size:0.7rem; color:#8b949e; font-weight:500; text-transform:uppercase; letter-spacing:0.05em">Dark Factory</span>
            <span style={"font-size:0.8rem; font-weight:600; color:#{if @dark_factory, do: "#3fb950", else: "#8b949e"}"}>
              {if @dark_factory, do: "Fully Autonomous", else: "Manual Review"}
            </span>
          </div>
          <button 
            phx-click="toggle_dark_factory" 
            class={"btn #{if @dark_factory, do: "btn-green", else: "btn-grey"}"}
            style="padding:0.25rem 0.5rem; font-size:0.75rem"
          >
            {if @dark_factory, do: "Disable", else: "Enable"}
          </button>
        </div>
      </div>

      <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:0.75rem; margin-bottom:1.5rem">
        <%!-- Row 1 --%>
        <%!-- Sectors: col 1, spans 2 rows --%>
        <div class="card" style="grid-row:1 / 3">
          <div class="card-label">Sectors</div>
          <%= if @recent_sectors == [] do %>
            <div class="empty" style="font-size:0.8rem; padding:0.5rem 0">No sectors registered.</div>
          <% else %>
            <div style="display:flex; flex-direction:column; gap:0.4rem; margin-top:0.5rem">
              <%= for sector <- @recent_sectors do %>
                <div style={"display:flex; justify-content:space-between; align-items:center; padding:0.3rem 0.2rem; border-bottom:1px solid #21262d; border-left:2px solid #{if Map.get(sector, :id) == @current_sector_id, do: "#3b82f6", else: "transparent"}; padding-left:0.4rem"}>
                  <div style="display:flex; align-items:center; gap:0.4rem; overflow:hidden; flex:1">
                    <span style="color:#f0f6fc; font-weight:500; font-size:0.85rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap">{Map.get(sector, :name, "-")}</span>
                    <%= if Map.get(sector, :id) == @current_sector_id do %>
                      <span class="badge badge-blue" style="font-size:0.55rem; flex-shrink:0">active</span>
                    <% end %>
                  </div>
                  <%= if Map.get(sector, :id) != @current_sector_id do %>
                    <button phx-click="use_sector" phx-value-id={sector.id} style="background:none; border:1px solid #30363d; color:#8b949e; font-size:0.6rem; padding:0.1rem 0.4rem; border-radius:3px; cursor:pointer; flex-shrink:0">use</button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
          <div style="margin-top:auto; padding-top:0.75rem">
            <a href="/dashboard/sectors" style="color:#58a6ff; font-size:0.8rem">Manage &rarr;</a>
          </div>
        </div>

        <%!-- Missions: col 2, spans 2 rows --%>
        <div class="card" style="grid-row:1 / 3">
          <div class="card-label">Missions</div>
          <%= if @recent_missions == [] do %>
            <div class="empty" style="font-size:0.8rem; padding:0.5rem 0">No missions.</div>
          <% else %>
            <div style="display:flex; flex-direction:column; gap:0.5rem; margin-top:0.5rem">
              <%= for mission <- @recent_missions do %>
                <a href={"/dashboard/missions/#{mission.id}"} style="text-decoration:none; display:block; padding:0.4rem 0; border-bottom:1px solid #21262d">
                  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.3rem">
                    <span style="color:#f0f6fc; font-weight:500; font-size:0.8rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:60%">
                      {Map.get(mission, :name) || String.slice(Map.get(mission, :goal, ""), 0, 30)}
                    </span>
                    <div style="display:flex; gap:0.25rem; align-items:center">
                      <%= if mission.ghost_count > 0 do %>
                        <span style="font-size:0.6rem; color:#58a6ff">{mission.ghost_count} <span style="opacity:0.6">ghost{if mission.ghost_count > 1, do: "s"}</span></span>
                      <% end %>
                      <span class={"badge #{mission_status_badge(Map.get(mission, :status))}"} style="font-size:0.6rem">
                        {Map.get(mission, :status, "?")}
                      </span>
                    </div>
                  </div>
                  <div style="display:flex; align-items:center; gap:6px">
                    <.mini_phase_pipeline phase={Map.get(mission, :current_phase, "pending")} />
                    <%!-- Budget micro-bar --%>
                    <div style="flex:1; height:3px; background:#21262d; border-radius:2px; overflow:hidden; min-width:30px" title={"Budget: #{mission.budget_pct}%"}>
                      <div style={"height:100%; border-radius:2px; background:#{cond do
                        mission.budget_pct >= 90 -> "#f85149"
                        mission.budget_pct >= 70 -> "#d29922"
                        true -> "#238636"
                      end}; width:#{min(mission.budget_pct, 100)}%"}></div>
                    </div>
                    <span style="font-size:0.6rem; color:#6b7280; white-space:nowrap">{mission.budget_pct}%</span>
                  </div>
                </a>
              <% end %>
            </div>
          <% end %>
          <div style="margin-top:auto; padding-top:0.75rem; display:flex; justify-content:space-between; align-items:center">
            <a href="/dashboard/missions" style="color:#58a6ff; font-size:0.8rem">View all &rarr;</a>
            <span style="color:#6b7280; font-size:0.75rem">{@quest_count} total</span>
          </div>
        </div>

        <%!-- Total Cost: col 3, spans 2 rows --%>
        <div class="card" style="grid-row:1 / 3">
          <div class="card-label">Total Cost</div>
          <div class="card-value green">{format_cost(@total_cost)}</div>
          <div class="card-label" style="margin-top:0.25rem">{format_tokens(@total_input_tokens + @total_output_tokens)} tokens</div>
          <%!-- Per-model cost bar chart --%>
          <%= if @cost_by_model != %{} do %>
            <div style="margin-top:0.75rem; border-top:1px solid #21262d; padding-top:0.75rem">
              <div style="font-size:0.7rem; color:#6b7280; margin-bottom:0.5rem">Cost by Model</div>
              <% max_cost = @cost_by_model |> Map.values() |> Enum.map(& &1.cost) |> Enum.max(fn -> 0.001 end) %>
              <%= for {model, data} <- Enum.sort_by(@cost_by_model, fn {_, d} -> -d.cost end) do %>
                <div style="margin-bottom:0.5rem">
                  <div style="display:flex; justify-content:space-between; font-size:0.7rem; margin-bottom:2px">
                    <span style="color:#c9d1d9; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:65%">{short_model_name(model)}</span>
                    <span style="color:#3fb950">{format_cost(data.cost)}</span>
                  </div>
                  <div style="height:4px; background:#21262d; border-radius:2px; overflow:hidden">
                    <div style={"height:100%; border-radius:2px; background:#{model_bar_color(model)}; width:#{Float.round(data.cost / max_cost * 100, 1)}%"}></div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Row 3: Active Ghosts, Quest Phases, Pending Approvals --%>
        <div class="card">
          <div class="card-label">Active Ghosts</div>
          <div class="card-value blue">{@active_ghosts}</div>
          <div class="card-label" style="margin-top:0.25rem">{@ghost_count} total</div>
        </div>
        <div class="card">
          <div class="card-label">Quest Phases</div>
          <div class="card-value purple">{@implementation_quests}</div>
          <div class="card-label" style="margin-top:0.25rem">
            R:{@research_quests} P:{@planning_quests} I:{@implementation_quests}
          </div>
        </div>
        <div class="card">
          <div class="card-label">Pending Approvals</div>
          <div class={"card-value #{if @pending_approvals > 0, do: "yellow"}"}>
            {@pending_approvals}
          </div>
          <div class="card-label" style="margin-top:0.25rem">
            <a href="/dashboard/approvals" style="color:#58a6ff; font-size:0.8rem">View queue</a>
          </div>
        </div>

        <%!-- Row 4: Context Fuel Gauge, Audit (under Total Cost) --%>
        <div class="card">
          <div class="card-label">Context Fuel</div>
          <%!-- Gas gauge: SVG arc --%>
          <div style="display:flex; justify-content:center; padding:0.5rem 0">
            <svg viewBox="0 0 120 70" width="120" height="70">
              <%!-- Background arc --%>
              <path d="M 15 60 A 45 45 0 0 1 105 60" fill="none" stroke="#21262d" stroke-width="8" stroke-linecap="round" />
              <%!-- Fuel arc — colored by level --%>
              <% fuel = @fuel_remaining %>
              <% arc_pct = fuel / 100.0 %>
              <% color = cond do
                fuel > 60 -> "#3fb950"
                fuel > 30 -> "#d29922"
                fuel > 10 -> "#f97316"
                true -> "#f85149"
              end %>
              <% # Arc endpoint: angle goes from pi (left) to 0 (right) as fuel goes 0→100%
                 angle = :math.pi * (1.0 - arc_pct)
                 ex = 60 + 45 * :math.cos(angle)
                 ey = 60 - 45 * :math.sin(angle)
                 large = if arc_pct > 0.5, do: "1", else: "0"
              %>
              <%= if arc_pct > 0.01 do %>
                <path
                  d={"M 15 60 A 45 45 0 #{large} 1 #{Float.round(ex, 1)} #{Float.round(ey, 1)}"}
                  fill="none"
                  stroke={color}
                  stroke-width="8"
                  stroke-linecap="round"
                />
              <% end %>
              <%!-- Center text --%>
              <text x="60" y="55" text-anchor="middle" fill={color} font-size="16" font-weight="bold">
                {Float.round(fuel, 0) |> trunc()}%
              </text>
              <text x="60" y="67" text-anchor="middle" fill="#6b7280" font-size="8">
                remaining
              </text>
            </svg>
          </div>
          <div style="display:flex; justify-content:space-between; font-size:0.7rem; color:#6b7280; padding:0 0.25rem">
            <span>peak: {Float.round(@peak_context, 1)}%</span>
            <span>{length(@active_ghost_list)} active</span>
          </div>
          <%= if @high_context_bees > 0 do %>
            <div style="font-size:0.7rem; color:#f97316; margin-top:0.25rem; text-align:center">
              {if @high_context_bees > 0, do: "#{@high_context_bees} ghost(s) >40%"}
            </div>
          <% end %>
        </div>
        <div class="card">
          <div class="card-label">Audit</div>
          <div class={"card-value #{if @failed_verification > 0, do: "red", else: "green"}"}>
            {@verified_jobs}
          </div>
          <div class="card-label" style="margin-top:0.25rem">
            {if @failed_verification > 0, do: "#{@failed_verification} failed", else: "#{@pending_verification} pending"}
          </div>
        </div>
      </div>

      <!-- Quick Run -->
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Quick Run</div>
        <p style="color:#8b949e; font-size:0.8rem; margin-bottom:0.75rem">
          Run a focused task (bug fix, single feature) — skips the full pipeline, spawns one ghost immediately.
        </p>
        <form phx-submit="quick_run" style="display:flex; gap:0.5rem; align-items:flex-end">
          <input
            type="text"
            name="task[goal]"
            class="form-input"
            placeholder="e.g. fix the login timeout bug"
            style="flex:1"
          />
          <button type="submit" class="btn btn-green" style="white-space:nowrap">Run</button>
        </form>
      </div>

      <div style="display:flex; gap:0.5rem; margin-bottom:1.5rem; flex-wrap:wrap">
        <a href="/dashboard/missions/new" class="btn btn-blue">New Mission</a>
        <a href="/dashboard/timeline" class="btn btn-grey">Timeline</a>
        <a href="/dashboard/health" class="btn btn-grey">Health</a>
        <a href="/dashboard/shells" class="btn btn-grey">Shells</a>
        <a href="/dashboard/autonomy" class="btn btn-grey">Self-Heal</a>
      </div>

      <%!-- Factory operations bar --%>
      <div style="display:flex; gap:1.5rem; margin-bottom:1.5rem; padding:0.6rem 1rem; background:#161b22; border:1px solid #21262d; border-radius:6px; font-size:0.8rem; flex-wrap:wrap">
        <div style="display:flex; align-items:center; gap:0.3rem">
          <.dot color="#3fb950" /> <span style="color:#3fb950; font-weight:600">{@active_ghosts}</span> <span style="color:#6b7280">ghosts working</span>
        </div>
        <div style="display:flex; align-items:center; gap:0.3rem">
          <.dot color="#58a6ff" /> <span style="color:#58a6ff; font-weight:600">{@active_quests}</span> <span style="color:#6b7280">missions active</span>
        </div>
        <div style="display:flex; align-items:center; gap:0.3rem">
          <.dot color="#d29922" /> <span style="color:#d29922; font-weight:600">{@pending_approvals}</span> <span style="color:#6b7280">approvals waiting</span>
        </div>
        <div style="display:flex; align-items:center; gap:0.3rem">
          <span style="color:#6b7280">Today:</span>
          <span style="color:#3fb950; font-weight:600">{@completed_today}</span>
          <span style="color:#6b7280">done</span>
          <%= if @failed_today > 0 do %>
            <span style="color:#f85149; font-weight:600">{@failed_today}</span>
            <span style="color:#6b7280">failed</span>
          <% end %>
          <span style="color:#484f58">&middot;</span>
          <span style="color:#8b949e">{@ops_completed_today} ops</span>
        </div>
      </div>

      <div class="panel">
        <div class="panel-title">Recent Messages</div>
        <%= if @recent_waggles == [] do %>
          <div class="empty">No messages yet.</div>
        <% else %>
          <%= for link_msg <- @recent_waggles do %>
            <div class={"link_msg-item #{unless link_msg.read, do: "link_msg-unread"}"}>
              <div class="link_msg-subject" style="display:flex;align-items:center;"><.link_msg_icon subject={link_msg.subject} /> {link_msg.subject || "(no subject)"}</div>
              <div class="link_msg-meta">
                {link_msg.from} &rarr; {link_msg.to}
                &middot;
                {format_timestamp(link_msg.inserted_at)}
                &middot;
                <span class={"badge #{if link_msg.read, do: "badge-grey", else: "badge-blue"}"}>
                  {if link_msg.read, do: "read", else: "unread"}
                </span>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </.live_component>
    """
  end
end
