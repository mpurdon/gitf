defmodule GiTF.Dashboard.PlanLive do
  @moduledoc "Real-time plan viewer with grouped checklists tracking op execution."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable
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
          |> assign(:refresh_scheduled, false)
          |> init_toasts()
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

  def handle_event("approve_plan", _params, socket) do
    mission = socket.assigns.mission
    specs = GiTF.Missions.get_artifact(mission.id, "planning") || []

    GiTF.Major.Planner.create_jobs_from_specs(mission.id, specs)
    GiTF.Major.Orchestrator.advance_quest(mission.id)

    {:noreply,
     socket
     |> push_toast(:success, "Plan approved — #{length(specs)} ops created")
     |> refresh_after_action()}
  end

  def handle_event("reject_plan", _params, socket) do
    mission = socket.assigns.mission
    quest_record = GiTF.Archive.get(:missions, mission.id)

    if quest_record do
      updated = Map.delete(quest_record, :draft_plan)
      GiTF.Archive.put(:missions, updated)
    end

    {:noreply,
     socket
     |> push_toast(:warning, "Plan rejected — will be re-planned")
     |> refresh_after_action()}
  end

  defp refresh_after_action(socket) do
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> refresh_data(socket, mission)
      _ -> socket
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> {:noreply, refresh_data(socket, mission)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}
  end

  def handle_info({:gitf_event, _}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  # Debounced refresh: collapse rapid PubSub events into one mission re-fetch 150ms out.
  def handle_info(:debounced_refresh, socket) do
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} ->
        {:noreply, socket |> assign(:refresh_scheduled, false) |> refresh_data(mission)}

      _ ->
        {:noreply, assign(socket, :refresh_scheduled, false)}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
    <.breadcrumbs crumbs={[{"Missions", "/dashboard/missions"}, {Map.get(@mission, :name, "Mission"), "/dashboard/missions/#{@mission.id}"}, {"Plan", nil}]} />

    <%!-- Header --%>
    <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:1.25rem; flex-wrap:wrap; gap:0.75rem">
      <div>
        <h1 class="page-title" style="margin-bottom:0.25rem">
          Plan: {Map.get(@mission, :name, "Mission")}
        </h1>
        <div style="color:#8b949e; font-size:0.85rem; max-width:700px">{@mission[:goal]}</div>
      </div>
      <div style="display:flex; gap:0.5rem; align-items:center">
        <span class={"badge #{phase_badge(@mission[:current_phase] || "pending")}"}>{@mission[:current_phase] || "pending"}</span>
        <%= if @mission[:review_plan] and @mission[:current_phase] in ["planning", "pending"] do %>
          <button phx-click="approve_plan" class="btn btn-green" style="font-size:0.8rem" data-confirm="Approve this plan and create ops?">Approve Plan</button>
          <button phx-click="reject_plan" class="btn btn-red" style="font-size:0.8rem" data-confirm="Reject this plan?">Reject</button>
        <% end %>
        <button phx-click="expand_all" class="btn btn-grey" style="font-size:0.75rem; padding:0.2rem 0.5rem">Expand All</button>
        <button phx-click="collapse_all" class="btn btn-grey" style="font-size:0.75rem; padding:0.2rem 0.5rem">Collapse All</button>
      </div>
    </div>

    <%!-- Stats Cards --%>
    <div class="plan-stats">
      <div class="plan-stat">
        <div class="plan-stat-value green">{@done_count}</div>
        <div class="plan-stat-label">Done</div>
      </div>
      <div class="plan-stat">
        <div class={"plan-stat-value #{if @running_count > 0, do: "blue", else: ""}"}>
          {@running_count}
        </div>
        <div class="plan-stat-label">Running</div>
      </div>
      <div class="plan-stat">
        <div class={"plan-stat-value #{if @blocked_count > 0, do: "yellow", else: ""}"}>
          {@blocked_count}
        </div>
        <div class="plan-stat-label">Blocked</div>
      </div>
      <div class="plan-stat">
        <div class={"plan-stat-value #{if @failed_count > 0, do: "red", else: ""}"}>
          {@failed_count}
        </div>
        <div class="plan-stat-label">Failed</div>
      </div>
      <div class="plan-stat">
        <div class="plan-stat-value">{@total_count}</div>
        <div class="plan-stat-label">Total</div>
      </div>
    </div>

    <%!-- Overall Progress --%>
    <div class="panel" style="margin-bottom:1.25rem; padding:0.85rem 1.25rem">
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.35rem">
        <span style="font-size:0.85rem; color:#8b949e">Overall Progress</span>
        <span style="font-size:0.85rem; font-weight:600; font-family:monospace; color:#f0f6fc">
          {Float.round(progress_pct(@done_count, @total_count), 0) |> trunc()}%
        </span>
      </div>
      <div class="plan-progress">
        <div class="plan-progress-fill" style={"width: #{progress_pct(@done_count, @total_count)}%"}></div>
      </div>
    </div>


    <%!-- Execution lanes: the dependency DAG as columns. Ops sharing a lane
         run as parallel ghosts; the flat checklist below cannot show that. --%>
    <div :if={length(@lanes) > 0} class="panel" style="margin-bottom:1.25rem; padding:0.85rem 1.25rem">
      <div class="panel-title" style="font-size:0.85rem; margin-bottom:0.75rem; padding-bottom:0.4rem; display:flex; justify-content:space-between; align-items:baseline">
        Execution Lanes
        <span style="font-size:0.68rem; font-weight:400; color:#6b7280">
          each column starts when the one before it finishes &middot; cards in a column run in parallel
        </span>
      </div>
      <div style="display:flex; gap:0.9rem; overflow-x:auto; align-items:stretch; padding-bottom:0.25rem">
        <%= for {{depth, items}, i} <- Enum.with_index(@lanes) do %>
          <div :if={i > 0} style="align-self:center; color:#484f58; font-size:1.1rem">&rarr;</div>
          <div style="flex:1; min-width:14rem; display:flex; flex-direction:column; gap:0.5rem">
            <div style="font-size:0.65rem; letter-spacing:0.1em; text-transform:uppercase; color:#6b7280">
              stage {depth + 1}
              <span :if={length(items) > 1} style="color:#58a6ff">&middot; {length(items)} in parallel</span>
            </div>
            <div
              :for={item <- items}
              phx-click="toggle_op"
              phx-value-id={Map.get(item, :id) || Map.get(item, "title", "")}
              style={"background:#161b22; border:1px solid #30363d; border-left:3px solid #{lane_color(item)}; border-radius:6px; padding:0.55rem 0.7rem; cursor:pointer"}
            >
              <div style="display:flex; align-items:center; gap:0.4rem">
                <span style="flex:1; font-size:0.8rem; color:#f0f6fc; line-height:1.3">
                  {Map.get(item, :title) || Map.get(item, "title", "Untitled")}
                </span>
                <span :if={item[:status]} class={"badge #{status_badge(item[:status])}"} style="font-size:0.62rem">{item[:status]}</span>
              </div>
              <div style="display:flex; flex-wrap:wrap; gap:0.3rem; margin-top:0.4rem">
                <span
                  :for={rid <- List.wrap(item[:requirement_ids] || item["requirement_ids"] || [])}
                  style="font-size:0.62rem; font-family:monospace; color:#58a6ff; background:#1f6feb22; border-radius:3px; padding:0.05rem 0.3rem"
                >{rid}</span>
                <span
                  :if={(item[:target_files] || item["target_files"] || []) != []}
                  style="font-size:0.62rem; color:#6b7280"
                >{length(List.wrap(item[:target_files] || item["target_files"]))} file(s)</span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <%!-- Plan-only mode notice --%>
    <div :if={@mode == :plan_only} class="panel" style="padding:1.5rem; text-align:center; margin-bottom:1rem; color:#8b949e">
      Awaiting implementation — ops will appear when the mission enters the implementation phase.
    </div>

    <%!-- Grouped Ops --%>
    <div :for={{group_label, items} <- @grouped_items}>
      <% done = Enum.count(items, &(Map.get(&1, :status, "pending") == "done"))
         running = Enum.count(items, &(Map.get(&1, :status) in ["running", "assigned"]))
         total = length(items)
         group_open = running > 0 or not MapSet.member?(@collapsed, group_label)
         pct = progress_pct(done, total) %>

      <div class="plan-group">
        <div class="plan-group-header" phx-click="toggle_group" phx-value-group={group_label}>
          <span class={"section-chevron #{if group_open, do: "open"}"}>▸</span>
          <span class="plan-group-title">{group_label}</span>
          <span class="plan-group-count">{done}/{total}</span>
          <div class="plan-group-progress">
            <div class="plan-group-progress-fill" style={"width: #{pct}%"}></div>
          </div>
          <span class="plan-group-pct">{Float.round(pct, 0) |> trunc()}%</span>
        </div>

        <div :if={group_open}>
          <div :for={item <- items}>
            <% item_status = Map.get(item, :status, "pending")
               item_id = Map.get(item, :id) || Map.get(item, "title", "")
               expanded = MapSet.member?(@expanded_ops, item_id)
               ghost_info = if item[:ghost_id], do: Map.get(@ghost_names, item[:ghost_id])
               {g_provider, _g_short, _g_tier} = if ghost_info, do: parse_model(ghost_info[:model]), else: {nil, nil, nil}
               status_class = case item_status do
                 s when s in ["running", "assigned"] -> "checklist-item-running"
                 "failed" -> "checklist-item-failed"
                 "blocked" -> "checklist-item-blocked"
                 "done" -> "checklist-item-done"
                 _ -> ""
               end %>

            <div
              class={"checklist-item #{status_class}"}
              phx-click="toggle_op"
              phx-value-id={item_id}
            >
              <span class={"status-icon status-icon-#{status_icon_class(item_status)}"}>{status_icon(item_status)}</span>
              <span style="flex:1; color:#f0f6fc; font-size:0.9rem">{Map.get(item, :title) || Map.get(item, "title", "Untitled")}</span>
              <span :if={ghost_info} class={"model-badge #{provider_class(g_provider)}"}>{ghost_badge_label(ghost_info[:name], ghost_info[:model])}</span>
              <span :if={item[:ghost_id] && is_nil(ghost_info)} class="ghost-tag">{short_id(item[:ghost_id])}</span>
              <span class={"badge #{status_badge(item_status)}"}>{item_status}</span>
              <span :if={item[:verification_status] == "passed"} class="badge badge-green" style="font-size:0.7rem">verified</span>
              <span :if={item[:verification_status] == "failed"} class="badge badge-red" style="font-size:0.7rem">failed</span>
            </div>

            <div :if={expanded} class="plan-detail">
              <%!-- Description — rendered as structured markdown --%>
              <div :if={item[:description] || item["description"]} class="plan-desc">
                {format_description(item[:description] || item["description"])}
              </div>

              <% criteria = List.wrap(item[:acceptance_criteria] || item["acceptance_criteria"] || [])
                 target_files = List.wrap(item[:target_files] || item["target_files"] || [])
                 changed = List.wrap(item[:changed_files] || [])
                 deps = Map.get(@dep_map, item_id || item[:id], [])
                 has_left = criteria != [] or deps != []
                 has_right = target_files != [] or changed != [] %>

              <div :if={has_left or has_right} class={if has_left and has_right, do: "plan-detail-grid", else: ""}>
                <%!-- Left column: criteria + deps --%>
                <div :if={has_left}>
                  <div :if={criteria != []} class="plan-detail-section">
                    <div class="plan-detail-heading">Acceptance Criteria</div>
                    <div :for={c <- criteria} class="criteria-item">
                      <span :if={item[:verification_status] == "passed"} class="coverage-ok">✓</span>
                      <span :if={item[:verification_status] == "failed"} class="coverage-gap">✗</span>
                      <span :if={item[:verification_status] not in ["passed", "failed"]} style="color:#484f58">○</span>
                      <span>{c}</span>
                    </div>
                  </div>

                  <div :if={deps != []} class="plan-detail-section">
                    <div class="plan-detail-heading">Dependencies</div>
                    <div :for={dep <- deps} style="display:flex; align-items:center; gap:0.4rem; padding:0.2rem 0; font-size:0.85rem">
                      <span class={"status-icon status-icon-#{status_icon_class(dep.status)}"} style="font-size:0.8rem">{status_icon(dep.status)}</span>
                      <span style="color:#c9d1d9">{dep.title}</span>
                    </div>
                  </div>
                </div>

                <%!-- Right column: files (vertical list) --%>
                <div :if={has_right}>
                  <div :if={target_files != []} class="plan-detail-section">
                    <div class="plan-detail-heading">Target Files</div>
                    <div :for={f <- target_files} class="plan-file-item">{f}</div>
                  </div>

                  <div :if={changed != []} class="plan-detail-section">
                    <div class="plan-detail-heading" style="color:#3fb950">Changed Files ({length(changed)})</div>
                    <div :for={f <- changed} class="plan-file-item" style="border-color:#3fb950">{f}</div>
                  </div>
                </div>
              </div>
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

    lanes =
      case mode do
        :live ->
          compute_lanes(lane_nodes(:live, impl_ops, dep_map))

        :plan_only ->
          compute_lanes(lane_nodes(:plan_only, normalize_plan_specs(plan_artifact), dep_map))
      end

    ghost_names = build_ghost_names(impl_ops)
    done_count = Enum.count(impl_ops, &(&1.status == "done"))
    running_count = Enum.count(impl_ops, &(&1.status in ["running", "assigned"]))
    blocked_count = Enum.count(impl_ops, &(&1.status == "blocked"))
    failed_count = Enum.count(impl_ops, &(&1.status == "failed"))
    total_count = length(impl_ops)

    socket
    |> assign(:mission, mission)
    |> assign(:mode, mode)
    |> assign(:ops, impl_ops)
    |> assign(:grouped_items, grouped_items)
    |> assign(:dep_map, dep_map)
    |> assign(:lanes, lanes)
    |> assign(:ghost_names, ghost_names)
    |> assign(:done_count, done_count)
    |> assign(:running_count, running_count)
    |> assign(:blocked_count, blocked_count)
    |> assign(:failed_count, failed_count)
    |> assign(:total_count, max(total_count, 1))
  end

  # -- Execution lanes --------------------------------------------------------

  # Arranges ops into dependency-depth lanes: lane 0 holds everything with no
  # prerequisites, lane N holds work that must wait for something in lane
  # N-1. Ops sharing a lane run as PARALLEL ghosts — which is the fact the
  # flat checklist hid: a 4-op plan with two independent lanes reads there as
  # one long queue, and the operator reasonably concluded the factory works
  # one ghost at a time.
  #
  # Takes {key, dep_keys, item} tuples so live ops (id-keyed, deps from
  # :op_dependencies) and plan-only specs (index-keyed, deps from
  # depends_on_indices) both fit. A dep key that names a missing node is
  # ignored; a cycle degrades to depth-so-far rather than looping.
  @doc false
  def compute_lanes(nodes) do
    by_key = Map.new(nodes, fn {key, _deps, _item} = n -> {key, n} end)

    depth_of = fn depth_of, key, seen ->
      case Map.get(by_key, key) do
        nil ->
          -1

        {_key, deps, _item} ->
          deps
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.map(&depth_of.(depth_of, &1, MapSet.put(seen, key)))
          |> case do
            [] -> 0
            ds -> Enum.max(ds) + 1
          end
      end
    end

    nodes
    |> Enum.group_by(fn {key, _deps, _item} -> depth_of.(depth_of, key, MapSet.new()) end)
    |> Enum.sort_by(fn {depth, _} -> depth end)
    |> Enum.map(fn {depth, lane_nodes} ->
      {depth, Enum.map(lane_nodes, fn {_k, _d, item} -> item end)}
    end)
  end

  defp lane_color(item) do
    case item[:status] do
      s when s in ["running", "assigned"] -> "#58a6ff"
      "done" -> "#3fb950"
      "failed" -> "#f85149"
      "blocked" -> "#d29922"
      _ -> "#484f58"
    end
  end

  defp lane_nodes(:live, ops, dep_map) do
    Enum.map(ops, fn op ->
      dep_ids = dep_map |> Map.get(op.id, []) |> Enum.map(& &1.id)
      {op.id, dep_ids, op}
    end)
  end

  defp lane_nodes(:plan_only, specs, _dep_map) do
    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, idx} ->
      deps = List.wrap(spec[:depends_on_indices] || spec["depends_on_indices"] || [])
      {idx, deps, spec}
    end)
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

  # -- Description formatting ------------------------------------------------

  @doc false
  defp format_description(nil), do: ""

  defp format_description(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> parse_desc_lines([])
    |> Phoenix.HTML.raw()
  end

  defp format_description(_), do: ""

  # Parse lines into structured HTML sections
  defp parse_desc_lines([], acc), do: acc |> Enum.reverse() |> Enum.join("\n")

  defp parse_desc_lines([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      # Empty line
      trimmed == "" ->
        parse_desc_lines(rest, acc)

      # Numbered heading: "1. **file.tsx**:" or "1. file.tsx:"
      Regex.match?(~r/^\d+\.\s+/, trimmed) ->
        heading_html =
          trimmed
          |> String.replace(~r/^\d+\.\s+/, "")
          |> inline_md()

        html = ~s(<div class="plan-desc-heading">#{heading_html}</div>)
        parse_desc_lines(rest, [html | acc])

      # Bullet line: "- text" or "  - text"
      Regex.match?(~r/^\s*-\s+/, trimmed) ->
        content = String.replace(trimmed, ~r/^\s*-\s+/, "") |> inline_md()
        # Check indent level for sub-bullets
        indent = line |> String.replace(~r/[^\s].*/, "") |> String.length()
        cls = if indent >= 4, do: "plan-desc-sub-bullet", else: "plan-desc-bullet"
        html = ~s(<div class="#{cls}">#{content}</div>)
        parse_desc_lines(rest, [html | acc])

      # Regular paragraph text
      true ->
        html = ~s(<div class="plan-desc-para">#{inline_md(trimmed)}</div>)
        parse_desc_lines(rest, [html | acc])
    end
  end

  # Inline markdown: **bold**, `code`, *italic*
  defp inline_md(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/`([^`]+)`/, "<code class=\"plan-inline-code\">\\1</code>")
  end

  defp progress_pct(done, total) when total > 0, do: Float.round(done / total * 100, 1)
  defp progress_pct(_, _), do: 0
end
