defmodule GiTF.Dashboard.PlanLive do
  @moduledoc "Real-time plan viewer with grouped checklists tracking op execution."

  use Phoenix.LiveView
  import GiTF.Dashboard.Helpers
  alias GiTF.Dashboard.PlanGrouping

  @refresh_ms 5_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
          Phoenix.PubSub.subscribe(GiTF.PubSub, "section:monitor")
          Process.send_after(self(), :refresh, @refresh_ms)
        end

        socket =
          socket
          |> assign(:page_title, "Plan: #{Map.get(mission, :name, "Mission")}")
          |> assign(:current_path, "/dashboard/missions")
          |> assign(:collapsed, MapSet.new())
          |> assign(:expanded_ops, MapSet.new())
          |> refresh_data(mission)

        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Mission not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) do
    {:noreply, assign(socket, :collapsed, toggle_set(socket.assigns.collapsed, group))}
  end

  def handle_event("toggle_op", %{"id" => op_id}, socket) do
    {:noreply, assign(socket, :expanded_ops, toggle_set(socket.assigns.expanded_ops, op_id))}
  end

  def handle_event("expand_all", _params, socket) do
    all_ids = socket.assigns.ops |> Enum.map(& &1.id) |> MapSet.new()
    {:noreply, assign(socket, expanded_ops: all_ids, collapsed: MapSet.new())}
  end

  def handle_event("collapse_all", _params, socket) do
    all_groups = socket.assigns.grouped_items |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    {:noreply, assign(socket, expanded_ops: MapSet.new(), collapsed: all_groups)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> {:noreply, refresh_data(socket, mission)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:waggle_received, _}, socket) do
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> {:noreply, refresh_data(socket, mission)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:gitf_event, _}, socket) do
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> {:noreply, refresh_data(socket, mission)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>

    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
      <div>
        <h1 class="page-title" style="margin-bottom:0.25rem">Plan: {Map.get(@mission, :name, "Mission")}</h1>
        <div style="color:#8b949e; font-size:0.85rem">{@mission[:goal]}</div>
      </div>
      <div style="display:flex; gap:0.5rem; align-items:center">
        <span class={"badge #{phase_badge(@mission[:current_phase] || "pending")}"}>{@mission[:current_phase] || "pending"}</span>
        <a href={"/dashboard/missions/#{@mission.id}"} class="btn btn-grey">Back</a>
      </div>
    </div>

    <div class="panel" style="margin-bottom:1rem">
      <div style="display:flex; justify-content:space-between; align-items:center">
        <span style="font-size:0.9rem">Plan Progress: {@done_count}/{@total_count} ops complete</span>
        <div style="display:flex; gap:0.5rem">
          <button phx-click="expand_all" class="btn btn-grey" style="font-size:0.75rem; padding:0.2rem 0.5rem">Expand All</button>
          <button phx-click="collapse_all" class="btn btn-grey" style="font-size:0.75rem; padding:0.2rem 0.5rem">Collapse All</button>
        </div>
      </div>
      <div class="plan-progress">
        <div class="plan-progress-fill" style={"width: #{progress_pct(@done_count, @total_count)}%"}></div>
      </div>
    </div>

    <div :if={@mode == :plan_only} class="panel" style="padding:1.5rem; text-align:center; margin-bottom:1rem; color:#8b949e">
      Awaiting implementation — ops will appear when the mission enters the implementation phase.
    </div>

    <div :for={{group_label, items} <- @grouped_items}>
      <% done = Enum.count(items, &(Map.get(&1, :status, "pending") == "done"))
         total = length(items)
         has_running = Enum.any?(items, &(Map.get(&1, :status) in ["running", "assigned"]))
         group_open = has_running or not MapSet.member?(@collapsed, group_label) %>

      <div class="section-header" phx-click="toggle_group" phx-value-group={group_label}>
        <span class={"section-chevron #{if group_open, do: "open"}"}>▸</span>
        {group_label}
        <span style="color:#8b949e; font-weight:400; font-size:0.85rem; margin-left:0.25rem">{done}/{total} complete</span>
        <div class="group-progress">
          <div class="group-progress-fill" style={"width: #{progress_pct(done, total)}%"}></div>
        </div>
      </div>

      <div :if={group_open} style="margin-bottom:0.5rem">
        <div :for={item <- items}>
          <% item_status = Map.get(item, :status, "pending")
             item_id = Map.get(item, :id) || Map.get(item, "title", "")
             expanded = MapSet.member?(@expanded_ops, item_id)
             ghost_info = if item[:ghost_id], do: Map.get(@ghost_names, item[:ghost_id])
             {g_provider, _g_short, _g_tier} = if ghost_info, do: parse_model(ghost_info[:model]), else: {nil, nil, nil} %>

          <div
            class={"checklist-item #{if item_status == "done", do: "checklist-item-done"}"}
            phx-click="toggle_op"
            phx-value-id={item_id}
          >
            <span class={"status-icon status-icon-#{status_icon_class(item_status)}"}>{status_icon(item_status)}</span>
            <span style="flex:1; color:#f0f6fc">{Map.get(item, :title) || Map.get(item, "title", "Untitled")}</span>
            <span :if={ghost_info} class={"model-badge #{provider_class(g_provider)}"}>{ghost_badge_label(ghost_info[:name], ghost_info[:model])}</span>
            <span :if={item[:ghost_id] && is_nil(ghost_info)} class="ghost-tag">{short_id(item[:ghost_id])}</span>
            <span class={"badge #{status_badge(item_status)}"}>{item_status}</span>
            <span :if={item[:verification_status] == "passed"} class="badge badge-green" style="font-size:0.7rem">verified</span>
            <span :if={item[:verification_status] == "failed"} class="badge badge-red" style="font-size:0.7rem">failed</span>
          </div>

          <div :if={expanded} style="padding:0.5rem 0.75rem 0.75rem 2.5rem; border-bottom:1px solid #21262d; background:#0d1117">
            <div :if={item[:description] || item["description"]} style="font-size:0.85rem; color:#8b949e; margin-bottom:0.5rem; white-space:pre-wrap">
              {item[:description] || item["description"]}
            </div>

            <% criteria = List.wrap(item[:acceptance_criteria] || item["acceptance_criteria"] || []) %>
            <div :if={criteria != []} style="margin-bottom:0.5rem">
              <div style="font-size:0.8rem; color:#8b949e; margin-bottom:0.25rem; font-weight:600">Acceptance Criteria</div>
              <div :for={c <- criteria} class="criteria-item">
                <span :if={item[:verification_status] == "passed"} class="coverage-ok">✓</span>
                <span :if={item[:verification_status] == "failed"} class="coverage-gap">✗</span>
                <span :if={item[:verification_status] not in ["passed", "failed"]} style="color:#8b949e">○</span>
                <span>{c}</span>
              </div>
            </div>

            <% target_files = List.wrap(item[:target_files] || item["target_files"] || []) %>
            <div :if={target_files != []} style="margin-bottom:0.5rem">
              <div style="font-size:0.8rem; color:#8b949e; margin-bottom:0.25rem; font-weight:600">Target Files</div>
              <span :for={f <- target_files} class="file-tag">{f}</span>
            </div>

            <% changed = List.wrap(item[:changed_files] || []) %>
            <div :if={changed != []} style="margin-bottom:0.5rem">
              <div style="font-size:0.8rem; color:#3fb950; margin-bottom:0.25rem; font-weight:600">Changed Files ({length(changed)})</div>
              <span :for={f <- changed} class="file-tag" style="border-color:#3fb950">{f}</span>
            </div>

            <% deps = Map.get(@dep_map, item_id || item[:id], []) %>
            <div :if={deps != []} style="margin-top:0.25rem; font-size:0.85rem; color:#d29922">
              Depends on:
              <span :for={dep <- deps}>
                <span class={"badge #{status_badge(dep.status)}"} style="font-size:0.7rem">{dep.title}</span>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div :if={@grouped_items == []} class="panel" style="text-align:center; padding:3rem; color:#8b949e">
      No plan available for this mission.
    </div>

    </.live_component>
    """
  end

  # -- Data loading ----------------------------------------------------------

  defp refresh_data(socket, mission) do
    plan_artifact = GiTF.Missions.get_artifact(mission.id, "planning")

    # Get implementation ops (filter out phase ops)
    all_ops = GiTF.Ops.list(mission_id: mission.id)
    impl_ops = Enum.reject(all_ops, & &1[:phase_job])

    {mode, grouped_items} =
      if impl_ops != [] do
        {:live, PlanGrouping.group_ops(impl_ops)}
      else
        specs = normalize_plan_specs(plan_artifact)
        if specs != [], do: {:plan_only, PlanGrouping.group_specs(specs)}, else: {:plan_only, []}
      end

    dep_map = build_dep_map(impl_ops)
    ghost_names = build_ghost_names(impl_ops)
    done_count = Enum.count(impl_ops, &(&1.status == "done"))
    total_count = length(impl_ops)

    socket
    |> assign(:mission, mission)
    |> assign(:mode, mode)
    |> assign(:ops, impl_ops)
    |> assign(:grouped_items, grouped_items)
    |> assign(:dep_map, dep_map)
    |> assign(:ghost_names, ghost_names)
    |> assign(:done_count, done_count)
    |> assign(:total_count, max(total_count, 1))
  end

  # -- Helpers ---------------------------------------------------------------

  defp normalize_plan_specs(specs) when is_list(specs), do: specs
  defp normalize_plan_specs(%{"tasks" => tasks}) when is_list(tasks), do: tasks
  defp normalize_plan_specs(%{tasks: tasks}) when is_list(tasks), do: tasks
  defp normalize_plan_specs(_), do: []

  defp build_dep_map(ops) do
    Enum.reduce(ops, %{}, fn op, acc ->
      deps = GiTF.Ops.dependencies(op.id)
      if deps == [], do: acc, else: Map.put(acc, op.id, deps)
    end)
  rescue
    _ -> %{}
  end

  defp build_ghost_names(ops) do
    ops
    |> Enum.map(& &1[:ghost_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn gid, acc ->
      case GiTF.Ghosts.get(gid) do
        {:ok, ghost} -> Map.put(acc, gid, %{name: ghost.name, model: ghost[:assigned_model]})
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  end

  defp progress_pct(done, total) when total > 0, do: Float.round(done / total * 100, 1)
  defp progress_pct(_, _), do: 0
end
