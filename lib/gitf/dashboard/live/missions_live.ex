defmodule GiTF.Dashboard.MissionsLive do
  @moduledoc """
  Quest management page.

  Displays all missions in a table with status badges. Quests can be
  expanded to reveal their constituent ops. Status colors provide
  visual feedback: green for completed, blue for active, grey for
  pending, red for failed.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  # Longer heartbeat — PubSub handles real-time updates
  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    # Avoid double-mount cost: skip the expensive load_quests on the initial
    # HTTP render. Connected mount does the real load.
    missions = if connected?(socket), do: load_quests(), else: []

    {:ok,
     socket
     |> assign(:page_title, "Missions")
     |> assign(:current_path, "/missions")
     |> assign(:all_missions, missions)
     |> assign(:search, "")
     |> assign(:status_filter, "all")
     |> assign(:sort_by, :priority)
     |> assign(:sort_dir, :asc)
     |> assign(:expanded, MapSet.new())
     |> assign(:refresh_scheduled, false)
     |> assign(:loading, false)
     |> init_toasts()
     |> stream_configure(:missions, dom_id: &"mission-#{&1.id}")
     |> stream(:missions, missions)
     |> assign(:missions_empty?, missions == [])}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}
  end

  # Debounced refresh: collapse rapid PubSub events into a single reload 150ms out.
  def handle_info(:debounced_refresh, socket) do
    parent = self()

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      missions = load_quests()
      send(parent, {:missions_loaded, missions})
    end)

    {:noreply, socket |> assign(:refresh_scheduled, false) |> assign(:loading, true)}
  end

  def handle_info({:missions_loaded, missions}, socket) do
    {:noreply,
     socket |> assign(:all_missions, missions) |> assign(:loading, false) |> apply_filters()}
  end

  def handle_info({:start_quest_result, {:ok, _}}, socket) do
    {:noreply, socket |> put_flash(:info, "Mission started.") |> schedule_refresh()}
  end

  def handle_info({:start_quest_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> put_flash(:error, "Failed to start: #{inspect(reason)}")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  @impl true
  def handle_event("toggle", %{"id" => mission_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, mission_id) do
        MapSet.delete(socket.assigns.expanded, mission_id)
      else
        MapSet.put(socket.assigns.expanded, mission_id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> apply_filters()}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:status_filter, status) |> apply_filters()}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    col = String.to_existing_atom(col)

    dir =
      if socket.assigns.sort_by == col do
        if socket.assigns.sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, socket |> assign(:sort_by, col) |> assign(:sort_dir, dir) |> apply_filters()}
  end

  def handle_event("start", %{"id" => id}, socket) do
    # Orchestrator.start_quest/1 can be slow (spawns ghost, writes archive).
    # Offload to async Task and refresh on PubSub event afterwards.
    parent = self()

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      result = GiTF.Major.Orchestrator.start_quest(id)
      send(parent, {:start_quest_result, result})
    end)

    {:noreply, socket |> put_flash(:info, "Starting mission...") |> assign(:loading, true)}
  end

  def handle_event("navigate", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/dashboard/missions/#{id}")}
  end

  defp apply_filters(socket) do
    search = String.downcase(socket.assigns.search || "")
    status_filter = socket.assigns.status_filter
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir

    filtered =
      socket.assigns.all_missions
      |> Enum.filter(fn m ->
        status_match =
          case status_filter do
            "all" -> true
            "active" -> Map.get(m, :status) in GiTF.Missions.active_statuses()
            "completed" -> Map.get(m, :status) == "completed"
            "failed" -> Map.get(m, :status) == "failed"
            _ -> true
          end

        search_match =
          if search == "" do
            true
          else
            name = String.downcase(Map.get(m, :name, "") || "")
            goal = String.downcase(Map.get(m, :goal, "") || "")
            String.contains?(name, search) or String.contains?(goal, search)
          end

        status_match and search_match
      end)
      |> sort_missions(sort_by, sort_dir)

    socket
    |> stream(:missions, filtered, reset: true)
    |> assign(:missions_empty?, filtered == [])
  end

  defp sort_missions(missions, col, dir) do
    sorter =
      case col do
        :priority -> &GiTF.Priority.weight(&1.effective_priority)
        :status -> &Map.get(&1, :status, "")
        :phase -> &Map.get(&1, :current_phase, "")
        :budget -> & &1.budget_pct
        :name -> &(Map.get(&1, :name, "") || "")
        _ -> &GiTF.Priority.weight(&1.effective_priority)
      end

    sorted = Enum.sort_by(missions, sorter)
    if dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp load_quests do
    GiTF.Missions.list()
    |> Enum.map(fn mission ->
      m =
        case GiTF.Missions.get(mission.id) do
          {:ok, q} -> q
          _ -> mission
        end

      # Enrich with priority + budget
      priority =
        try do
          GiTF.Priority.effective_priority(m)
        rescue
          _ -> Map.get(m, :priority, :normal)
        end

      budget_pct =
        try do
          budget = GiTF.Budget.budget_for(m.id)
          spent = GiTF.Budget.spent_for(m.id)
          if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0
        rescue
          _ -> 0.0
        end

      duration =
        case {m[:inserted_at], m[:updated_at]} do
          {%DateTime{} = s, %DateTime{} = e} when m.status in ["completed", "failed"] ->
            secs = DateTime.diff(e, s, :second)

            cond do
              secs < 60 -> "#{secs}s"
              secs < 3600 -> "#{div(secs, 60)}m"
              true -> "#{div(secs, 3600)}h#{rem(div(secs, 60), 60)}m"
            end

          {%DateTime{} = s, _} ->
            secs = DateTime.diff(DateTime.utc_now(), s, :second)

            cond do
              secs < 60 -> "#{secs}s"
              secs < 3600 -> "#{div(secs, 60)}m"
              true -> "#{div(secs, 3600)}h#{rem(div(secs, 60), 60)}m"
            end

          _ ->
            "-"
        end

      Map.merge(m, %{effective_priority: priority, budget_pct: budget_pct, duration: duration})
    end)
  end

  defp sort_arrow(current_col, dir, col) do
    if current_col == col do
      if dir == :asc, do: "▲", else: "▼"
    else
      ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">Missions</h1>
        <div style="display:flex; gap:0.5rem">
          <a href="/dashboard/missions/new" class="btn btn-green">New Mission</a>
          <button phx-click="refresh" class="btn btn-blue">Refresh</button>
        </div>
      </div>

      <%!-- Search + status filter --%>
      <div style="display:flex; gap:0.75rem; margin-bottom:1rem; align-items:center; flex-wrap:wrap">
        <form phx-change="search" style="flex:1; min-width:200px">
          <input
            type="text"
            name="q"
            value={@search}
            class="form-input"
            placeholder="Search missions..."
            phx-debounce="300"
            style="width:100%; font-size:0.85rem"
          />
        </form>
        <div style="display:flex; gap:0.25rem">
          <%= for {label, key} <- [{"All", "all"}, {"Active", "active"}, {"Completed", "completed"}, {"Failed", "failed"}] do %>
            <button
              phx-click="filter_status"
              phx-value-status={key}
              class={"btn #{if @status_filter == key, do: "btn-blue", else: "btn-grey"}"}
              style="font-size:0.75rem; padding:0.25rem 0.5rem"
            >
              {label}
            </button>
          <% end %>
        </div>
      </div>

      <div class="panel">
        <%= if @missions_empty? do %>
          <div class="empty">
            No missions created yet.
            <a href="/dashboard/missions/new" style="color:var(--accent)">Create your first mission</a>
          </div>
        <% else %>
          <table id="missions-table" phx-update="stream">
            <thead id="missions-thead">
              <tr>
                <th></th>
                <th>ID</th>
                <th class="sortable" phx-click="sort" phx-value-col="name">Name {sort_arrow(@sort_by, @sort_dir, :name)}</th>
                <th class="sortable" phx-click="sort" phx-value-col="priority">Priority {sort_arrow(@sort_by, @sort_dir, :priority)}</th>
                <th class="sortable" phx-click="sort" phx-value-col="status">Status {sort_arrow(@sort_by, @sort_dir, :status)}</th>
                <th class="sortable" phx-click="sort" phx-value-col="phase">Phase {sort_arrow(@sort_by, @sort_dir, :phase)}</th>
                <th class="sortable" phx-click="sort" phx-value-col="budget">Budget {sort_arrow(@sort_by, @sort_dir, :budget)}</th>
                <th>Duration</th>
                <th>Jobs</th>
                <th></th>
              </tr>
            </thead>
            <%= for {dom_id, mission} <- @streams.missions do %>
              <tbody id={dom_id}>
                <tr class="detail-toggle" phx-click="toggle" phx-value-id={mission.id}>
                  <td style="width:1.5rem">{if MapSet.member?(@expanded, mission.id), do: "v", else: ">"}</td>
                  <td style="font-family:monospace; font-size:0.8rem">{mission.id}</td>
                  <td>
                    <a href={"/dashboard/missions/#{mission.id}"} style="color:var(--accent)" phx-click="navigate" phx-value-id={mission.id}>
                      {Map.get(mission, :name, mission.goal)}
                    </a>
                  </td>
                  <td>
                    <span class={"badge #{case mission.effective_priority do
                      :critical -> "badge-red"
                      :high -> "badge-orange"
                      :normal -> "badge-blue"
                      :low -> "badge-grey"
                      _ -> "badge-grey"
                    end}"} style="font-size:0.65rem">{mission.effective_priority}</span>
                  </td>
                  <td><span class={"badge #{status_badge(Map.get(mission, :status, "unknown"))}"}>{Map.get(mission, :status, "unknown")}</span></td>
                  <td><span class={"badge #{phase_badge(Map.get(mission, :current_phase, "pending"))}"}>
                    {Map.get(mission, :current_phase, "pending")}
                  </span></td>
                  <td>
                    <div style="display:flex; align-items:center; gap:0.3rem; min-width:60px">
                      <div style="flex:1; height:4px; background:var(--line-2); border-radius:2px; overflow:hidden">
                        <div style={"height:100%; border-radius:2px; background:#{cond do
                          mission.budget_pct >= 90 -> "var(--crit)"
                          mission.budget_pct >= 70 -> "var(--warn)"
                          true -> "var(--ok)"
                        end}; width:#{min(mission.budget_pct, 100)}%"}></div>
                      </div>
                      <span style="font-size:0.65rem; color:var(--muted)">{mission.budget_pct}%</span>
                    </div>
                  </td>
                  <td style="font-size:0.8rem; color:var(--muted)">{mission.duration}</td>
                  <td>{job_count(mission)}</td>
                  <td>
                    <%= if Map.get(mission, :status) == "pending" do %>
                      <button phx-click="start" phx-value-id={mission.id} class="btn btn-green" style="padding:0.2rem 0.6rem; font-size:0.75rem">
                        Start
                      </button>
                    <% end %>
                  </td>
                </tr>
                <%= if MapSet.member?(@expanded, mission.id) do %>
                  <tr>
                    <td colspan="10" style="padding:0">
                      <div class="detail-content">
                        <%= if has_jobs?(mission) do %>
                          <table>
                            <thead>
                              <tr>
                                <th>Job ID</th>
                                <th>Title</th>
                                <th>Status</th>
                                <th>Audit</th>
                                <th>Ghost ID</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for op <- mission.ops do %>
                                <tr>
                                  <td style="font-family:monospace; font-size:0.8rem">{op.id}</td>
                                  <td>{op.title}</td>
                                  <td><span class={"badge #{status_badge(Map.get(op, :status, "unknown"))}"}>{Map.get(op, :status, "unknown")}</span></td>
                                  <td>
                                    <%= if Map.get(op, :verification_status) do %>
                                      <span class={"badge #{verification_badge(op.verification_status)}"}>
                                        {op.verification_status}
                                      </span>
                                    <% else %>
                                      <span class="badge badge-grey">-</span>
                                    <% end %>
                                  </td>
                                  <td style="font-family:monospace; font-size:0.8rem">{op.ghost_id || "-"}</td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        <% else %>
                          <div class="empty" style="text-align:left">No ops in this mission.</div>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            <% end %>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end

  defp has_jobs?(%{ops: ops}) when is_list(ops), do: ops != []
  defp has_jobs?(_), do: false

  defp job_count(%{ops: ops}) when is_list(ops), do: "#{length(ops)}"
  defp job_count(_), do: "-"
end
