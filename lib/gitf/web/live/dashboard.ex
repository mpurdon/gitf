defmodule GiTF.Web.Live.Dashboard do
  use Phoenix.LiveView

  alias GiTF.Store
  alias GiTF.PubSubBridge

  @refresh_interval 3_000

  # ── Mount ──────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubBridge.subscribe()
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    socket =
      socket
      |> assign(:page_title, "Factory Floor")
      |> assign(:node, Node.self())
      |> assign(:cluster_size, length(Node.list()) + 1)
      |> assign(:emergency_stop_triggered, false)
      |> assign(:selected_job_id, nil)
      |> assign(:selected_quest_id, nil)
      |> assign(:feed_expanded, false)
      |> assign(:show_done_jobs, false)
      |> assign(:show_inactive_quests, false)
      # New assigns
      |> assign(:active_tab, :detail)
      |> assign(:refresh_count, 0)
      |> assign(:events, [])
      |> assign(:health, safe_call(fn -> GiTF.Observability.Health.check() end, %{status: :unknown, checks: %{}, timestamp: DateTime.utc_now()}))
      |> assign(:alerts, safe_call(fn -> GiTF.Observability.Alerts.check_alerts() end, []))
      |> assign(:merge_queue, safe_call(fn -> GiTF.Merge.Queue.status() end, %{pending: [], active: nil, completed: []}))
      |> assign(:runs, safe_call(fn -> GiTF.Run.list(status: "active") end, []))
      |> assign(:event_store_events, [])
      |> assign(:event_types, safe_call(fn -> GiTF.EventStore.event_types() end, []))
      |> assign(:agent_identities, safe_call(fn -> GiTF.AgentIdentity.list() end, []))
      |> assign(:checkpoints, %{})
      |> assign(:budget_status, [])
      |> assign(:event_type_filter, nil)
      |> assign(:selected_model, nil)
      |> assign_stats()
      |> then(fn s -> assign(s, :budget_status, load_budget_status(s.assigns.quests)) end)

    {:ok, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("emergency_stop", _params, socket) do
    active_ghosts = Store.filter(:ghosts, fn b -> b[:status] == "working" end)

    Enum.each(active_ghosts, fn ghost ->
      GiTF.Ghosts.stop(ghost[:id])
    end)

    GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
      type: :emergency_stop,
      message: "Emergency Stop triggered by operator"
    })

    {:noreply, assign(socket, :emergency_stop_triggered, true)}
  end

  def handle_event("reset_stop", _params, socket) do
    {:noreply, assign(socket, :emergency_stop_triggered, false)}
  end

  def handle_event("select_job", %{"id" => job_id}, socket) do
    current = socket.assigns.selected_job_id
    new_id = if current == job_id, do: nil, else: job_id
    {:noreply, socket |> assign(:selected_job_id, new_id) |> assign(:active_tab, :detail)}
  end

  def handle_event("close_job_detail", _params, socket) do
    {:noreply, assign(socket, :selected_job_id, nil)}
  end

  def handle_event("toggle_feed", _params, socket) do
    {:noreply, assign(socket, :feed_expanded, !socket.assigns.feed_expanded)}
  end

  def handle_event("retry_job", %{"id" => job_id}, socket) do
    GiTF.Jobs.reset(job_id)
    {:noreply, assign_stats(socket)}
  end

  def handle_event("kill_job", %{"id" => job_id}, socket) do
    GiTF.Jobs.kill(job_id)
    {:noreply, socket |> assign(:selected_job_id, nil) |> assign_stats()}
  end

  def handle_event("kill_quest", %{"id" => quest_id}, socket) do
    GiTF.Quests.kill(quest_id)
    {:noreply, socket |> assign(:selected_job_id, nil) |> assign(:selected_quest_id, nil) |> assign_stats()}
  end

  def handle_event("select_quest", %{"id" => quest_id}, socket) do
    current = socket.assigns.selected_quest_id
    new_id = if current == quest_id, do: nil, else: quest_id
    {:noreply, socket |> assign(:selected_quest_id, new_id) |> assign(:selected_job_id, nil) |> assign(:active_tab, :detail)}
  end

  def handle_event("toggle_done_jobs", _params, socket) do
    {:noreply, assign(socket, :show_done_jobs, !socket.assigns.show_done_jobs)}
  end

  def handle_event("toggle_inactive_quests", _params, socket) do
    {:noreply, assign(socket, :show_inactive_quests, !socket.assigns.show_inactive_quests)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom =
      try do
        String.to_existing_atom(tab)
      rescue
        ArgumentError -> :detail
      end

    socket = assign(socket, :active_tab, tab_atom)
    socket = maybe_refresh_tab(socket)
    {:noreply, socket}
  end

  def handle_event("filter_events", %{"type" => ""}, socket) do
    socket =
      socket
      |> assign(:event_type_filter, nil)
      |> assign(:event_store_events, safe_call(fn -> GiTF.EventStore.list(limit: 50) end, []))

    {:noreply, socket}
  end

  def handle_event("filter_events", %{"type" => type}, socket) do
    type_atom =
      try do
        String.to_existing_atom(type)
      rescue
        ArgumentError -> nil
      end

    socket =
      socket
      |> assign(:event_type_filter, type_atom)
      |> assign(:event_store_events, safe_call(fn -> GiTF.EventStore.list(limit: 50, type: type_atom) end, []))

    {:noreply, socket}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    current = socket.assigns.selected_model
    new_model = if current == model, do: nil, else: model
    {:noreply, assign(socket, :selected_model, new_model)}
  end

  def handle_event("view_quest_timeline", %{"id" => quest_id}, socket) do
    events = safe_call(fn -> GiTF.EventStore.list(limit: 50, quest_id: quest_id) end, [])

    socket =
      socket
      |> assign(:active_tab, :events)
      |> assign(:event_type_filter, nil)
      |> assign(:event_store_events, events)

    {:noreply, socket}
  end

  # ── Info handlers ──────────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    count = (socket.assigns[:refresh_count] || 0) + 1

    socket
    |> assign(:refresh_count, count)
    |> refresh_core()
    |> maybe_refresh_slow(count)
    |> maybe_refresh_tab()
    |> then(&{:noreply, &1})
  end

  def handle_info({:gitf_event, payload}, socket) do
    events = [payload | socket.assigns.events] |> Enum.take(50)

    socket =
      socket
      |> assign(:events, events)
      |> assign_stats()
      |> assign(:cluster_size, length(Node.list()) + 1)

    {:noreply, socket}
  end

  # ── Refresh helpers ────────────────────────────────────────────────────

  defp refresh_core(socket) do
    socket
    |> assign_stats()
    |> assign(:merge_queue, safe_call(fn -> GiTF.Merge.Queue.status() end, socket.assigns.merge_queue))
    |> assign(:runs, safe_call(fn -> GiTF.Run.list(status: "active") end, socket.assigns.runs))
    |> assign(:alerts, safe_call(fn -> GiTF.Observability.Alerts.check_alerts() end, socket.assigns.alerts))
  end

  defp maybe_refresh_slow(socket, count) when rem(count, 5) == 0 do
    ghosts = socket.assigns.ghosts

    checkpoints =
      ghosts
      |> Enum.filter(&(&1[:status] == "working"))
      |> Enum.reduce(%{}, fn ghost, acc ->
        case safe_call(fn -> GiTF.Checkpoint.load(ghost[:id]) end, :error) do
          {:ok, cp} -> Map.put(acc, ghost[:id], cp)
          _ -> acc
        end
      end)

    socket
    |> assign(:health, safe_call(fn -> GiTF.Observability.Health.check() end, socket.assigns.health))
    |> assign(:agent_identities, safe_call(fn -> GiTF.AgentIdentity.list() end, socket.assigns.agent_identities))
    |> assign(:budget_status, load_budget_status(socket.assigns.quests))
    |> assign(:checkpoints, checkpoints)
  end

  defp maybe_refresh_slow(socket, _count), do: socket

  defp maybe_refresh_tab(%{assigns: %{active_tab: :events}} = socket) do
    opts = [limit: 50]
    opts = if socket.assigns.event_type_filter, do: Keyword.put(opts, :type, socket.assigns.event_type_filter), else: opts
    assign(socket, :event_store_events, safe_call(fn -> GiTF.EventStore.list(opts) end, socket.assigns.event_store_events))
  end

  defp maybe_refresh_tab(socket), do: socket

  defp assign_stats(socket) do
    stats = GiTF.Observability.Metrics.collect_metrics()
    quests = Store.all(:quests)
    jobs = Store.all(:jobs)
    ghosts = Store.all(:ghosts)

    selected_job =
      case socket.assigns[:selected_job_id] do
        nil -> nil
        id -> Enum.find(jobs, &(&1.id == id))
      end

    selected_quest =
      case socket.assigns[:selected_quest_id] do
        nil -> nil
        id -> Enum.find(quests, &(&1[:id] == id))
      end

    socket
    |> assign(:stats, stats)
    |> assign(:quests, quests)
    |> assign(:jobs, jobs)
    |> assign(:ghosts, ghosts)
    |> assign(:selected_job, selected_job)
    |> assign(:selected_quest, selected_quest)
  end

  defp load_budget_status(quests) do
    quests
    |> Enum.filter(&(&1[:status] in ["active", "pending"]))
    |> Enum.map(fn q ->
      budget = GiTF.Budget.budget_for(q[:id])
      spent = safe_call(fn -> GiTF.Budget.spent_for(q[:id]) end, 0.0)
      remaining = Float.round(budget - spent, 2)
      %{quest_id: q[:id], budget: budget, spent: spent, remaining: max(remaining, 0.0)}
    end)
  rescue
    _ -> []
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen p-6 flex flex-col">
      {render_header(assigns)}
      {render_kpi_row(assigns)}

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6 flex-1 min-h-0 mb-4">
        <div class="space-y-4">
          {render_sidebar(assigns)}
        </div>
        <div class="lg:col-span-3 flex flex-col">
          {render_tab_bar(assigns)}
          <div class="flex-1 min-h-0">
            {render_tab_content(assigns)}
          </div>
        </div>
      </div>

      {render_status_strip(assigns)}

      <div class="text-center text-gray-500 text-xs py-2">GiTF v<%= Application.spec(:gitf, :vsn) |> to_string() %></div>

      <!-- Feed Modal -->
      <%= if @feed_expanded do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-black bg-opacity-70" phx-click="toggle_feed">
          <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-600 w-3/4 h-3/4 flex flex-col" phx-click-away="toggle_feed">
            <div class="bg-gray-700 px-4 py-2 border-b border-gray-600 flex justify-between items-center rounded-t-lg shrink-0">
              <h3 class="font-bold">Real-time Feed</h3>
              <button phx-click="toggle_feed" class="text-gray-400 hover:text-white text-sm px-2 py-1 rounded hover:bg-gray-600">✕ Close</button>
            </div>
            <div class="p-4 overflow-y-auto flex-1 font-mono text-xs">
              <%= for event <- @events do %>
                <div class="mb-2 pb-2 border-b border-gray-700 last:border-0">
                  <span class="text-gray-500 mr-2">[<%= if ts = event[:timestamp], do: Calendar.strftime(ts, "%H:%M:%S"), else: "—" %>]</span>
                  <span class="text-blue-300 font-bold"><%= event[:event] || "unknown" %></span>
                  <span class="text-gray-400 ml-2">Node: <%= (event[:metadata] || %{}) |> Map.get(:node, "local") %></span>
                  <div class="pl-4 text-gray-300 mt-1">
                    <%= inspect(Map.drop(event[:metadata] || %{}, [:node])) %>
                  </div>
                </div>
              <% end %>
              <%= if Enum.empty?(@events) do %>
                <p class="text-gray-500 italic">Waiting for events...</p>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Components ─────────────────────────────────────────────────────────

  defp render_header(assigns) do
    ~H"""
    <header class="mb-6 flex justify-between items-center border-b border-gray-700 pb-4">
      <div class="flex items-center gap-4">
        <div>
          <h1 class="text-3xl font-bold text-yellow-500">GiTF Factory Floor</h1>
          <p class="text-sm text-gray-400">Node: <%= @node %> | Cluster Size: <%= @cluster_size %></p>
        </div>
        <!-- Health dots -->
        <div class="flex items-center gap-1 ml-4">
          <%= for {name, status} <- @health[:checks] || %{} do %>
            <div title={"#{name}: #{status}"} class={"w-2.5 h-2.5 rounded-full #{health_dot(status)}"}></div>
          <% end %>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <!-- Alert count -->
        <%= if length(@alerts) > 0 do %>
          <span class="bg-yellow-900 text-yellow-300 px-2 py-1 rounded text-xs font-bold"><%= length(@alerts) %> alert<%= if length(@alerts) != 1, do: "s" %></span>
        <% end %>

        <%= if @emergency_stop_triggered do %>
          <button phx-click="reset_stop" class="bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded animate-pulse">
            SYSTEM HALTED - RESET
          </button>
        <% else %>
          <button phx-click="emergency_stop" data-confirm="Are you sure? This kills all active ghosts." class="bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded shadow-lg border-2 border-red-800">
            E-STOP
          </button>
        <% end %>
      </div>
    </header>
    """
  end

  defp render_kpi_row(assigns) do
    total_budget = Enum.reduce(assigns.budget_status, 0.0, &(&1.budget + &2))
    total_spent = Enum.reduce(assigns.budget_status, 0.0, &(&1.spent + &2))
    over_budget_count = Enum.count(assigns.budget_status, &(&1.spent > &1.budget))

    assigns =
      assigns
      |> Map.put(:total_budget, total_budget)
      |> Map.put(:total_spent, total_spent)
      |> Map.put(:over_budget_count, over_budget_count)

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4 mb-6">
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Active Bees</h3>
        <p class="text-3xl font-mono text-blue-400"><%= @stats.ghosts.active %></p>
      </div>
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Jobs</h3>
        <p class="text-3xl font-mono text-yellow-400"><%= @stats.jobs.pending + @stats.jobs.running %></p>
        <p class="text-xs text-gray-500"><%= @stats.jobs.pending %> pending · <%= @stats.jobs.running %> running · <%= @stats.jobs.done %> done</p>
      </div>
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Quests</h3>
        <p class="text-3xl font-mono text-green-400"><%= @stats.quests.total %></p>
        <p class="text-xs text-gray-500"><%= @stats.quests.active %> active · <%= @stats.quests.completed %> completed</p>
      </div>
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Burn Rate</h3>
        <p class="text-3xl font-mono text-red-400">$<%= (@stats.costs.total / 1) |> Float.round(2) %></p>
      </div>
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Budget</h3>
        <p class="text-3xl font-mono text-purple-400">
          <%= if @total_budget > 0, do: "#{Float.round(@total_spent / @total_budget * 100, 0)}%", else: "—" %>
        </p>
        <p class="text-xs text-gray-500">
          $<%= Float.round(@total_spent, 2) %> / $<%= Float.round(@total_budget, 2) %>
          <%= if @over_budget_count > 0 do %>
            <span class="text-red-400 ml-1"><%= @over_budget_count %> over</span>
          <% end %>
        </p>
      </div>
      <div class="bg-gray-800 p-3 rounded-lg shadow border border-gray-700">
        <h3 class="text-gray-400 text-xs uppercase">Quality</h3>
        <p class="text-3xl font-mono text-emerald-400">
          <%= if @stats.quality.count > 0, do: "#{Float.round(@stats.quality.average * 100, 0)}%", else: "—" %>
        </p>
        <p class="text-xs text-gray-500"><%= @stats.quality.count %> scored</p>
      </div>
    </div>
    """
  end

  defp render_sidebar(assigns) do
    ~H"""
    <!-- Quests -->
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700">
      <div class="bg-gray-700 px-3 py-1.5 border-b border-gray-600 flex justify-between items-center">
        <h3 class="font-bold text-sm">Quests</h3>
        <button phx-click="toggle_inactive_quests" class={"text-xs px-1.5 py-0.5 rounded #{if @show_inactive_quests, do: "bg-blue-700 text-blue-200", else: "text-gray-400 hover:text-gray-200"}"}>
          <%= if @show_inactive_quests, do: "all", else: "active" %>
        </button>
      </div>
      <% filtered_quests = if @show_inactive_quests do
        @quests
      else
        Enum.filter(@quests, fn q -> (q[:status] || "pending") in ["pending", "active", "failed"] end)
      end %>
      <div class="p-3 space-y-1 max-h-48 overflow-y-auto hive-scrollbar">
        <%= if Enum.empty?(filtered_quests) do %>
          <p class="text-gray-500 text-sm italic">No quests</p>
        <% end %>
        <%= for q <- filtered_quests do %>
          <div
            phx-click="select_quest"
            phx-value-id={q[:id]}
            class={"flex items-center justify-between text-sm group cursor-pointer rounded px-2 py-1 hover:bg-gray-700 #{if @selected_quest_id == q[:id], do: "bg-gray-700 ring-1 ring-green-500", else: ""}"}
          >
            <span class="truncate mr-2" title={q[:goal]}><%= q[:name] || q[:goal] || q[:id] %></span>
            <div class="flex items-center gap-1 shrink-0">
              <span class={"px-1.5 py-0.5 rounded text-xs font-mono #{quest_badge(q[:status] || "pending")}"}><%= q[:status] || "pending" %></span>
              <button
                phx-click="kill_quest"
                phx-value-id={q[:id]}
                data-confirm="Kill this quest and all its jobs?"
                class="hidden group-hover:inline-block text-red-500 hover:text-red-400 text-xs px-1"
                title="Kill quest and all jobs"
              >✕</button>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <!-- Workers -->
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700">
      <div class="bg-gray-700 px-3 py-1.5 border-b border-gray-600">
        <h3 class="font-bold text-sm">Workers</h3>
      </div>
      <div class="p-3 text-sm">
        <div class="flex justify-between mb-1">
          <span class="text-gray-400">Active</span>
          <span class="text-blue-400 font-mono"><%= @stats.ghosts.active %></span>
        </div>
        <div class="flex justify-between mb-1">
          <span class="text-gray-400">Idle</span>
          <span class="text-gray-300 font-mono"><%= @stats.ghosts.idle %></span>
        </div>
        <div class="flex justify-between mb-1">
          <span class="text-gray-400">Stopped</span>
          <span class="text-gray-500 font-mono"><%= @stats.ghosts.stopped %></span>
        </div>
        <div class="flex justify-between pt-2 border-t border-gray-700">
          <span class="text-gray-400">Total</span>
          <span class="text-white font-mono"><%= @stats.ghosts.total %></span>
        </div>
        <div class="mt-2 pt-2 border-t border-gray-700">
          <span class="text-gray-500 text-xs">Memory: <%= Float.round(@stats.system.memory_mb, 1) %> MB</span>
        </div>
      </div>
    </div>

    <!-- Jobs -->
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700">
      <div class="bg-gray-700 px-3 py-1.5 border-b border-gray-600 flex justify-between items-center">
        <h3 class="font-bold text-sm">Jobs</h3>
        <button phx-click="toggle_done_jobs" class={"text-xs px-1.5 py-0.5 rounded #{if @show_done_jobs, do: "bg-blue-700 text-blue-200", else: "text-gray-400 hover:text-gray-200"}"}>
          <%= if @show_done_jobs, do: "all", else: "active" %>
        </button>
      </div>
      <% filtered_jobs = if @show_done_jobs do
        @jobs
      else
        Enum.reject(@jobs, fn j -> j[:status] in ["done"] end)
      end %>
      <div class="p-3 space-y-1 max-h-48 overflow-y-auto hive-scrollbar">
        <%= if Enum.empty?(filtered_jobs) do %>
          <p class="text-gray-500 text-sm italic">No jobs</p>
        <% end %>
        <%= for j <- Enum.sort_by(filtered_jobs, & &1[:status]) do %>
          <div
            phx-click="select_job"
            phx-value-id={j[:id]}
            class={"flex items-center justify-between text-sm cursor-pointer rounded px-2 py-1 hover:bg-gray-700 #{if @selected_job_id == j[:id], do: "bg-gray-700 ring-1 ring-blue-500", else: ""}"}
          >
            <span class="truncate mr-2" title={j[:title]}><%= String.slice(j[:title] || "untitled", 0, 30) %></span>
            <span class={"px-1.5 py-0.5 rounded text-xs font-mono shrink-0 #{job_badge(j[:status])}"}><%= j[:status] || "?" %></span>
          </div>
        <% end %>
      </div>
    </div>

    <!-- Active Runs -->
    <%= if @runs != [] do %>
      <div class="bg-gray-800 rounded-lg shadow border border-gray-700">
        <div class="bg-gray-700 px-3 py-1.5 border-b border-gray-600">
          <h3 class="font-bold text-sm">Active Runs</h3>
        </div>
        <div class="p-3 space-y-2 max-h-48 overflow-y-auto hive-scrollbar">
          <%= for run <- @runs do %>
            <% quest = Enum.find(@quests, &(&1[:id] == run.quest_id)) %>
            <div class="text-sm">
              <div class="flex justify-between items-center mb-1">
                <span class="text-gray-300 truncate text-xs" title={run.quest_id}>
                  <%= if quest, do: quest[:name] || quest[:goal] || run.quest_id, else: run.quest_id %>
                </span>
                <span class={"px-1.5 py-0.5 rounded text-xs font-mono #{run_badge(run.status)}"}><%= run.status %></span>
              </div>
              <div class="w-full bg-gray-700 rounded-full h-1.5">
                <% pct = if run.total_jobs > 0, do: run.completed_jobs / run.total_jobs * 100, else: 0 %>
                <div class="bg-blue-500 h-1.5 rounded-full" style={"width: #{pct}%"}></div>
              </div>
              <p class="text-xs text-gray-500 mt-0.5"><%= run.completed_jobs %>/<%= run.total_jobs %> jobs</p>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_tab_bar(assigns) do
    tabs = [
      {:detail, "Detail"},
      {:pipeline, "Pipeline"},
      {:events, "Events"},
      {:merges, "Merges"},
      {:models, "Models"}
    ]

    assigns = Map.put(assigns, :tabs, tabs)

    ~H"""
    <div class="flex gap-1 mb-3">
      <%= for {id, label} <- @tabs do %>
        <button
          phx-click="switch_tab"
          phx-value-tab={id}
          class={"px-3 py-1.5 rounded-t text-sm font-medium #{if @active_tab == id, do: "bg-gray-800 text-white border border-b-0 border-gray-700", else: "text-gray-400 hover:text-gray-200 hover:bg-gray-800/50"}"}
        >
          <%= label %>
          <%= if id == :events && length(@event_store_events) > 0 do %>
            <span class="ml-1 text-xs text-gray-500">(<%= length(@event_store_events) %>)</span>
          <% end %>
          <%= if id == :merges && length((@merge_queue[:pending] || [])) > 0 do %>
            <span class="ml-1 text-xs text-yellow-500">(<%= length(@merge_queue[:pending]) %>)</span>
          <% end %>
        </button>
      <% end %>

      <!-- Feed toggle (right-aligned) -->
      <div class="ml-auto">
        <button phx-click="toggle_feed" class="text-gray-400 hover:text-white text-xs px-2 py-1.5 rounded hover:bg-gray-700">
          Feed (<%= length(@events) %>)
        </button>
      </div>
    </div>
    """
  end

  defp render_tab_content(%{active_tab: :detail} = assigns), do: render_detail_tab(assigns)
  defp render_tab_content(%{active_tab: :pipeline} = assigns), do: render_pipeline_tab(assigns)
  defp render_tab_content(%{active_tab: :events} = assigns), do: render_events_tab(assigns)
  defp render_tab_content(%{active_tab: :merges} = assigns), do: render_merges_tab(assigns)
  defp render_tab_content(%{active_tab: :models} = assigns), do: render_models_tab(assigns)
  defp render_tab_content(assigns), do: render_detail_tab(assigns)

  # ── Detail Tab ─────────────────────────────────────────────────────────

  defp render_detail_tab(assigns) do
    ~H"""
    <%= if @selected_job do %>
      <% stages = job_pipeline_stages(@selected_job, @merge_queue) %>
      <% checkpoint = @checkpoints[@selected_job[:ghost_id]] %>
      <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex flex-col">
        <div class="bg-gray-700 px-4 py-2 border-b border-gray-600 flex justify-between items-center shrink-0">
          <h3 class="font-bold">
            Job Detail
            <span class={"ml-2 px-2 py-0.5 rounded text-xs font-mono #{job_badge(@selected_job[:status])}"}><%= @selected_job[:status] || "unknown" %></span>
          </h3>
          <div class="flex items-center gap-2">
            <%= if @selected_job[:status] in ["failed"] do %>
              <button phx-click="retry_job" phx-value-id={@selected_job[:id]} class="text-xs px-3 py-1 rounded bg-yellow-700 hover:bg-yellow-600 text-white font-bold">Retry</button>
            <% end %>
            <button phx-click="kill_job" phx-value-id={@selected_job[:id]} data-confirm="Kill this job and clean up its ghost/cell?" class="text-xs px-3 py-1 rounded bg-red-700 hover:bg-red-600 text-white font-bold">Kill</button>
            <button phx-click="close_job_detail" class="text-gray-400 hover:text-white text-sm px-2 py-1 rounded hover:bg-gray-600">✕</button>
          </div>
        </div>
        <div class="p-5 flex flex-col flex-1 min-h-0 gap-4 overflow-y-auto hive-scrollbar">
          <!-- Pipeline Stage Indicator -->
          <div class="flex items-center gap-1 text-xs shrink-0">
            <%= for {label, status} <- stages do %>
              <div class={"px-2 py-1 rounded font-mono #{stage_badge(status)}"}><%= label %></div>
              <%= if label != "Merge" do %>
                <span class="text-gray-600">></span>
              <% end %>
            <% end %>
          </div>

          <!-- Title & ID -->
          <div class="shrink-0">
            <h4 class="text-lg text-white font-semibold"><%= @selected_job[:title] || "untitled" %></h4>
            <p class="text-xs text-gray-500 font-mono mt-1"><%= @selected_job[:id] %></p>
          </div>

          <!-- Metadata grid -->
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm shrink-0">
            <div>
              <span class="text-gray-500 block text-xs uppercase">Type</span>
              <span class="text-gray-300"><%= @selected_job[:job_type] || "—" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Complexity</span>
              <span class={"font-mono text-xs px-1.5 py-0.5 rounded #{complexity_badge(@selected_job[:complexity])}"}><%= @selected_job[:complexity] || "—" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Model</span>
              <span class="text-gray-300"><%= @selected_job[:assigned_model] || @selected_job[:recommended_model] || "—" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Retries</span>
              <span class="text-gray-300"><%= @selected_job[:retry_count] || 0 %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Bee</span>
              <span class="text-gray-300 font-mono text-xs"><%= @selected_job[:ghost_id] || "unassigned" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Quest</span>
              <span class="text-gray-300 font-mono text-xs"><%= @selected_job[:quest_id] || "—" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Verification</span>
              <span class={"text-xs font-mono #{verification_color(@selected_job[:verification_status])}"}><%= @selected_job[:verification_status] || "—" %></span>
            </div>
            <div>
              <span class="text-gray-500 block text-xs uppercase">Risk</span>
              <span class="text-gray-300"><%= @selected_job[:risk_level] || "—" %></span>
            </div>
          </div>

          <!-- Checkpoint -->
          <%= if checkpoint do %>
            <div class="shrink-0 bg-gray-900 rounded p-3">
              <span class="text-gray-500 text-xs uppercase block mb-2">Checkpoint (iter <%= checkpoint[:iteration] || "?" %>)</span>
              <div class="grid grid-cols-2 md:grid-cols-4 gap-3 text-xs">
                <div>
                  <span class="text-gray-500 block">Progress</span>
                  <span class="text-gray-300"><%= checkpoint[:progress_summary] || "—" %></span>
                </div>
                <div>
                  <span class="text-gray-500 block">Files Modified</span>
                  <span class="text-gray-300"><%= length(checkpoint[:files_modified] || []) %></span>
                </div>
                <div>
                  <span class="text-gray-500 block">Context Usage</span>
                  <% ctx_pct = (checkpoint[:context_usage_pct] || 0) * 100 %>
                  <div class="flex items-center gap-2">
                    <div class="w-16 bg-gray-700 rounded-full h-1.5">
                      <div class={"h-1.5 rounded-full #{if ctx_pct > 80, do: "bg-red-500", else: if(ctx_pct > 60, do: "bg-yellow-500", else: "bg-green-500")}"} style={"width: #{min(ctx_pct, 100)}%"}></div>
                    </div>
                    <span class="text-gray-400"><%= Float.round(ctx_pct, 0) %>%</span>
                  </div>
                </div>
                <div>
                  <span class="text-gray-500 block">Errors</span>
                  <span class={"#{if (checkpoint[:error_count] || 0) > 0, do: "text-red-400", else: "text-gray-300"}"}><%= checkpoint[:error_count] || 0 %></span>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Scout Findings -->
          <%= if @selected_job[:scout_findings] do %>
            <details class="shrink-0">
              <summary class="text-gray-500 text-xs uppercase cursor-pointer hover:text-gray-300">Scout Findings</summary>
              <div class="bg-gray-900 rounded p-3 mt-1 whitespace-pre-wrap font-mono text-xs text-gray-300 max-h-48 overflow-y-auto hive-scrollbar">
                <%= if is_binary(@selected_job[:scout_findings]), do: @selected_job[:scout_findings], else: inspect(@selected_job[:scout_findings], pretty: true, limit: :infinity) %>
              </div>
            </details>
          <% end %>

          <!-- Description -->
          <%= if @selected_job[:description] do %>
            <div class="flex flex-col flex-1 min-h-0">
              <span class="text-gray-500 text-xs uppercase block mb-1 shrink-0">Description</span>
              <div class="bg-gray-900 rounded p-3 whitespace-pre-wrap overflow-y-auto font-mono text-xs text-gray-300 flex-1 min-h-0 hive-scrollbar"><%= @selected_job[:description] %></div>
            </div>
          <% end %>

          <!-- Verification Result -->
          <%= if @selected_job[:verification_result] do %>
            <div class="shrink-0">
              <span class="text-gray-500 text-xs uppercase block mb-1">Verification Result</span>
              <div class="bg-gray-900 rounded p-3 whitespace-pre-wrap max-h-32 overflow-y-auto font-mono text-xs text-gray-300 hive-scrollbar"><%= inspect(@selected_job[:verification_result], pretty: true, limit: :infinity) %></div>
            </div>
          <% end %>

          <!-- Target Files -->
          <%= if @selected_job[:target_files] != nil and @selected_job[:target_files] != [] do %>
            <div class="shrink-0">
              <span class="text-gray-500 text-xs uppercase block mb-1">Target Files</span>
              <div class="flex flex-wrap gap-1">
                <%= for f <- @selected_job[:target_files] do %>
                  <span class="bg-gray-900 text-gray-400 text-xs font-mono px-2 py-0.5 rounded"><%= f %></span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% else %>
      <%= if @selected_quest do %>
        <% quest_jobs = Enum.filter(@jobs, fn j -> j[:quest_id] == @selected_quest[:id] end) %>
        <% budget_info = Enum.find(@budget_status, &(&1.quest_id == @selected_quest[:id])) %>
        <% active_run = Enum.find(@runs, &(&1.quest_id == @selected_quest[:id])) %>
        <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex flex-col">
          <div class="bg-gray-700 px-4 py-2 border-b border-gray-600 flex justify-between items-center shrink-0">
            <h3 class="font-bold">
              Quest Detail
              <span class={"ml-2 px-2 py-0.5 rounded text-xs font-mono #{quest_badge(@selected_quest[:status] || "pending")}"}><%= @selected_quest[:status] || "pending" %></span>
            </h3>
            <div class="flex items-center gap-2">
              <button phx-click="view_quest_timeline" phx-value-id={@selected_quest[:id]} class="text-xs px-3 py-1 rounded bg-gray-600 hover:bg-gray-500 text-white">Timeline</button>
              <button phx-click="kill_quest" phx-value-id={@selected_quest[:id]} data-confirm="Kill this quest and all its jobs?" class="text-xs px-3 py-1 rounded bg-red-700 hover:bg-red-600 text-white font-bold">Kill</button>
              <button phx-click="select_quest" phx-value-id={@selected_quest[:id]} class="text-gray-400 hover:text-white text-sm px-2 py-1 rounded hover:bg-gray-600">✕</button>
            </div>
          </div>
          <div class="p-5 flex flex-col flex-1 min-h-0 gap-4 overflow-y-auto hive-scrollbar">
            <div>
              <h4 class="text-lg text-white font-semibold"><%= @selected_quest[:name] || @selected_quest[:goal] || "untitled" %></h4>
              <p class="text-xs text-gray-500 font-mono mt-1"><%= @selected_quest[:id] %></p>
            </div>

            <div class="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm shrink-0">
              <div>
                <span class="text-gray-500 block text-xs uppercase">Goal</span>
                <span class="text-gray-300"><%= @selected_quest[:goal] || "—" %></span>
              </div>
              <div>
                <span class="text-gray-500 block text-xs uppercase">Phase</span>
                <span class="text-gray-300"><%= @selected_quest[:current_phase] || "—" %></span>
              </div>
              <div>
                <span class="text-gray-500 block text-xs uppercase">Comb</span>
                <span class="text-gray-300 font-mono text-xs"><%= @selected_quest[:comb_id] || "—" %></span>
              </div>
            </div>

            <!-- Budget Bar -->
            <%= if budget_info do %>
              <div class="shrink-0">
                <span class="text-gray-500 text-xs uppercase block mb-1">Budget</span>
                <% budget_pct = if budget_info.budget > 0, do: budget_info.spent / budget_info.budget * 100, else: 0 %>
                <div class="flex items-center gap-3">
                  <div class="flex-1 bg-gray-700 rounded-full h-2.5">
                    <div class={"h-2.5 rounded-full #{cond do
                      budget_pct >= 80 -> "bg-red-500"
                      budget_pct >= 60 -> "bg-yellow-500"
                      true -> "bg-green-500"
                    end}"} style={"width: #{min(budget_pct, 100)}%"}></div>
                  </div>
                  <span class="text-xs text-gray-400 font-mono shrink-0">$<%= Float.round(budget_info.spent, 2) %> / $<%= Float.round(budget_info.budget, 2) %></span>
                </div>
              </div>
            <% end %>

            <!-- Active Run -->
            <%= if active_run do %>
              <div class="shrink-0 bg-gray-900 rounded p-3">
                <span class="text-gray-500 text-xs uppercase block mb-1">Active Run</span>
                <div class="flex items-center gap-3">
                  <div class="flex-1 bg-gray-700 rounded-full h-1.5">
                    <% run_pct = if active_run.total_jobs > 0, do: active_run.completed_jobs / active_run.total_jobs * 100, else: 0 %>
                    <div class="bg-blue-500 h-1.5 rounded-full" style={"width: #{run_pct}%"}></div>
                  </div>
                  <span class="text-xs text-gray-400 font-mono shrink-0"><%= active_run.completed_jobs %>/<%= active_run.total_jobs %> jobs</span>
                </div>
              </div>
            <% end %>

            <!-- Quest Jobs -->
            <div class="shrink-0">
              <span class="text-gray-500 text-xs uppercase block mb-2">Jobs (<%= length(quest_jobs) %>)</span>
              <div class="space-y-1">
                <%= for j <- Enum.sort_by(quest_jobs, & &1[:status]) do %>
                  <div
                    phx-click="select_job"
                    phx-value-id={j[:id]}
                    class="flex items-center justify-between text-sm cursor-pointer rounded px-2 py-1 hover:bg-gray-700 bg-gray-900"
                  >
                    <span class="truncate mr-2"><%= j[:title] || "untitled" %></span>
                    <span class={"px-1.5 py-0.5 rounded text-xs font-mono shrink-0 #{job_badge(j[:status])}"}><%= j[:status] || "?" %></span>
                  </div>
                <% end %>
                <%= if Enum.empty?(quest_jobs) do %>
                  <p class="text-gray-500 text-sm italic">No jobs for this quest</p>
                <% end %>
              </div>
            </div>

            <!-- Research Summary -->
            <%= if @selected_quest[:research_summary] do %>
              <div class="flex flex-col flex-1 min-h-0">
                <span class="text-gray-500 text-xs uppercase block mb-1 shrink-0">Research Summary</span>
                <div class="bg-gray-900 rounded p-3 whitespace-pre-wrap overflow-y-auto font-mono text-xs text-gray-300 flex-1 min-h-0 hive-scrollbar"><%= @selected_quest[:research_summary] %></div>
              </div>
            <% end %>

            <!-- Implementation Plan -->
            <%= if @selected_quest[:implementation_plan] do %>
              <div class="flex flex-col flex-1 min-h-0">
                <span class="text-gray-500 text-xs uppercase block mb-1 shrink-0">Implementation Plan</span>
                <div class="bg-gray-900 rounded p-3 whitespace-pre-wrap overflow-y-auto font-mono text-xs text-gray-300 flex-1 min-h-0 hive-scrollbar"><%= @selected_quest[:implementation_plan] %></div>
              </div>
            <% end %>
          </div>
        </div>
      <% else %>
        <!-- Empty state -->
        <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex items-center justify-center">
          <div class="text-center text-gray-500 py-20">
            <p class="text-lg mb-2">Select a quest or job</p>
            <p class="text-sm">Click any item in the sidebar</p>
          </div>
        </div>
      <% end %>
    <% end %>
    """
  end

  # ── Pipeline Tab ───────────────────────────────────────────────────────

  defp render_pipeline_tab(assigns) do
    pipeline_jobs =
      assigns.jobs
      |> Enum.reject(&(&1[:status] == "done" && &1[:merged_at]))
      |> Enum.sort_by(&(&1[:status] || ""), :asc)
      |> then(fn jobs ->
        active = Enum.reject(jobs, &(&1[:status] == "done"))
        done = Enum.filter(jobs, &(&1[:status] == "done")) |> Enum.take(10)
        active ++ done
      end)

    assigns = Map.put(assigns, :pipeline_jobs, pipeline_jobs)

    ~H"""
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex flex-col">
      <div class="bg-gray-700 px-4 py-2 border-b border-gray-600 shrink-0">
        <h3 class="font-bold text-sm">Pipeline Stages</h3>
      </div>
      <div class="overflow-auto flex-1 hive-scrollbar">
        <table class="w-full text-sm">
          <thead class="text-xs text-gray-400 uppercase bg-gray-900 sticky top-0">
            <tr>
              <th class="px-3 py-2 text-left">Job</th>
              <th class="px-3 py-2 text-center">Scout</th>
              <th class="px-3 py-2 text-center">Triage</th>
              <th class="px-3 py-2 text-center">Bee</th>
              <th class="px-3 py-2 text-center">Drone</th>
              <th class="px-3 py-2 text-center">Merge</th>
            </tr>
          </thead>
          <tbody>
            <%= if Enum.empty?(@pipeline_jobs) do %>
              <tr><td colspan="6" class="px-3 py-8 text-center text-gray-500 italic">No jobs in pipeline</td></tr>
            <% end %>
            <%= for job <- @pipeline_jobs do %>
              <% stages = job_pipeline_stages(job, @merge_queue) %>
              <tr class="border-b border-gray-700/50 hover:bg-gray-700/30 cursor-pointer" phx-click="select_job" phx-value-id={job[:id]}>
                <td class="px-3 py-2 text-gray-300 truncate max-w-[200px]" title={job[:title]}>
                  <%= String.slice(job[:title] || "untitled", 0, 35) %>
                </td>
                <%= for {_label, status} <- stages do %>
                  <td class="px-3 py-2 text-center">
                    <span class={"px-2 py-0.5 rounded text-xs font-mono #{stage_badge(status)}"}><%= status %></span>
                  </td>
                <% end %>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── Events Tab ─────────────────────────────────────────────────────────

  defp render_events_tab(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex flex-col">
      <div class="bg-gray-700 px-4 py-2 border-b border-gray-600 flex justify-between items-center shrink-0">
        <h3 class="font-bold text-sm">Event Timeline</h3>
        <form phx-change="filter_events" class="flex items-center gap-2">
          <select name="type" class="bg-gray-800 border border-gray-600 rounded px-2 py-1 text-xs text-gray-300">
            <option value="">All events</option>
            <%= for t <- @event_types do %>
              <option value={t} selected={@event_type_filter == t}><%= t %></option>
            <% end %>
          </select>
        </form>
      </div>
      <div class="overflow-y-auto flex-1 p-3 font-mono text-xs hive-scrollbar">
        <%= if Enum.empty?(@event_store_events) do %>
          <p class="text-gray-500 italic text-center py-8">No events recorded yet</p>
        <% end %>
        <%= for event <- @event_store_events do %>
          <div class="mb-2 pb-2 border-b border-gray-700/50 last:border-0 flex items-start gap-2">
            <span class="text-gray-500 shrink-0">
              <%= if ts = event[:timestamp], do: Calendar.strftime(ts, "%H:%M:%S"), else: "—" %>
            </span>
            <span class={"px-1.5 py-0.5 rounded text-xs font-mono shrink-0 #{event_type_badge(event[:type])}"}><%= event[:type] %></span>
            <span class="text-gray-500 font-mono text-xs shrink-0"><%= short_id(event[:entity_id]) %></span>
            <span class="text-gray-400 truncate"><%= event_summary(event) %></span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Merges Tab ─────────────────────────────────────────────────────────

  defp render_merges_tab(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full flex flex-col overflow-y-auto hive-scrollbar">
      <div class="p-4 space-y-4">
        <!-- Active -->
        <div>
          <h3 class="text-xs uppercase text-gray-500 mb-2">Active Merge</h3>
          <%= if active = @merge_queue[:active] do %>
            <div class="bg-gray-900 rounded p-3 border border-blue-800 flex items-center gap-3">
              <div class="w-2 h-2 rounded-full bg-blue-500 animate-pulse"></div>
              <div>
                <span class="text-gray-300 font-mono text-sm"><%= short_id(active[:job_id] || active.job_id) %></span>
                <span class="text-gray-500 text-xs ml-2">cell: <%= active[:cell_id] || active.cell_id %></span>
              </div>
              <button phx-click="select_job" phx-value-id={active[:job_id] || active.job_id} class="ml-auto text-xs text-blue-400 hover:text-blue-300">View</button>
            </div>
          <% else %>
            <p class="text-gray-500 text-sm italic">No active merge</p>
          <% end %>
        </div>

        <!-- Pending -->
        <div>
          <h3 class="text-xs uppercase text-gray-500 mb-2">Pending (<%= length(@merge_queue[:pending] || []) %>)</h3>
          <%= if Enum.empty?(@merge_queue[:pending] || []) do %>
            <p class="text-gray-500 text-sm italic">Queue empty</p>
          <% end %>
          <div class="space-y-1">
            <%= for {{job_id, cell_id}, idx} <- Enum.with_index(@merge_queue[:pending] || []) do %>
              <div class="bg-gray-900 rounded px-3 py-2 flex items-center gap-3 text-sm">
                <span class="text-gray-500 font-mono text-xs w-6"><%= idx + 1 %></span>
                <span class="text-gray-300 font-mono"><%= short_id(job_id) %></span>
                <span class="text-gray-500 text-xs">cell: <%= cell_id %></span>
                <button phx-click="select_job" phx-value-id={job_id} class="ml-auto text-xs text-blue-400 hover:text-blue-300">View</button>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Completed -->
        <div>
          <h3 class="text-xs uppercase text-gray-500 mb-2">Recent Completed</h3>
          <%= if Enum.empty?(@merge_queue[:completed] || []) do %>
            <p class="text-gray-500 text-sm italic">No completed merges</p>
          <% end %>
          <div class="space-y-1">
            <%= for item <- @merge_queue[:completed] || [] do %>
              <% {job_id, outcome, timestamp} = item %>
              <div class="bg-gray-900 rounded px-3 py-2 flex items-center gap-3 text-sm">
                <span class="text-gray-300 font-mono"><%= short_id(job_id) %></span>
                <span class={"px-1.5 py-0.5 rounded text-xs font-mono #{merge_outcome_badge(outcome)}"}><%= format_outcome(outcome) %></span>
                <span class="text-gray-500 text-xs ml-auto"><%= Calendar.strftime(timestamp, "%H:%M:%S") %></span>
                <button phx-click="select_job" phx-value-id={job_id} class="text-xs text-blue-400 hover:text-blue-300">View</button>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Models Tab ─────────────────────────────────────────────────────────

  defp render_models_tab(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow border border-gray-700 h-full overflow-y-auto hive-scrollbar">
      <div class="p-4 space-y-3">
        <%= if Enum.empty?(@agent_identities) do %>
          <p class="text-gray-500 text-sm italic text-center py-8">No model data yet. Models appear after drone scoring.</p>
        <% end %>
        <%= for identity <- @agent_identities do %>
          <% pass_rate = if identity.total_jobs > 0, do: identity.total_passed / identity.total_jobs * 100, else: 0 %>
          <div class="bg-gray-900 rounded-lg border border-gray-700">
            <div
              class="p-3 cursor-pointer hover:bg-gray-800/50"
              phx-click="select_model"
              phx-value-model={identity.model}
            >
              <div class="flex justify-between items-center mb-2">
                <span class="text-white font-semibold"><%= identity.model %></span>
                <div class="flex items-center gap-3 text-xs text-gray-400">
                  <span><%= identity.total_jobs %> jobs</span>
                  <span class={"font-mono #{if pass_rate >= 80, do: "text-green-400", else: if(pass_rate >= 60, do: "text-yellow-400", else: "text-red-400")}"}><%= Float.round(pass_rate, 0) %>%</span>
                </div>
              </div>

              <!-- Score bars -->
              <div class="grid grid-cols-4 gap-2 text-xs">
                <%= for {label, key} <- [{"Correct", :correctness}, {"Complete", :completeness}, {"Quality", :code_quality}, {"Efficient", :efficiency}] do %>
                  <% score = (identity.avg_scores[key] || 0) * 100 %>
                  <div>
                    <div class="flex justify-between text-gray-500 mb-0.5">
                      <span><%= label %></span>
                      <span><%= Float.round(score, 0) %>%</span>
                    </div>
                    <div class="w-full bg-gray-700 rounded-full h-1">
                      <div class="bg-blue-500 h-1 rounded-full" style={"width: #{min(score, 100)}%"}></div>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- Strengths/Weaknesses badges -->
              <div class="flex flex-wrap gap-1 mt-2">
                <%= for s <- Enum.take(identity.strengths || [], 3) do %>
                  <span class="bg-green-900/50 text-green-400 text-xs px-1.5 py-0.5 rounded"><%= s.trait %></span>
                <% end %>
                <%= for w <- Enum.take(identity.weaknesses || [], 3) do %>
                  <span class="bg-red-900/50 text-red-400 text-xs px-1.5 py-0.5 rounded"><%= w.trait %></span>
                <% end %>
              </div>
            </div>

            <!-- Expanded detail -->
            <%= if @selected_model == identity.model do %>
              <div class="border-t border-gray-700 p-3 space-y-3">
                <!-- Best/Worst Job Types -->
                <div class="grid grid-cols-2 gap-4 text-xs">
                  <div>
                    <span class="text-gray-500 uppercase block mb-1">Best Job Types</span>
                    <%= for jt <- identity.best_job_types || [] do %>
                      <div class="flex justify-between text-gray-300 mb-0.5">
                        <span><%= jt.type %></span>
                        <span class="text-green-400 font-mono"><%= Float.round(jt.pass_rate * 100, 0) %>% (<%= jt.count %>)</span>
                      </div>
                    <% end %>
                  </div>
                  <div>
                    <span class="text-gray-500 uppercase block mb-1">Worst Job Types</span>
                    <%= for jt <- identity.worst_job_types || [] do %>
                      <div class="flex justify-between text-gray-300 mb-0.5">
                        <span><%= jt.type %></span>
                        <span class="text-red-400 font-mono"><%= Float.round(jt.pass_rate * 100, 0) %>% (<%= jt.count %>)</span>
                      </div>
                    <% end %>
                  </div>
                </div>

                <!-- Recent Jobs -->
                <div class="text-xs">
                  <span class="text-gray-500 uppercase block mb-1">Recent Jobs</span>
                  <div class="space-y-0.5">
                    <%= for rj <- Enum.take(identity.recent_jobs || [], 10) do %>
                      <div class="flex items-center gap-2 text-gray-400">
                        <span class={"w-1.5 h-1.5 rounded-full #{if rj.passed, do: "bg-green-500", else: "bg-red-500"}"}></span>
                        <span class="font-mono"><%= short_id(rj.job_id) %></span>
                        <span><%= rj.type %></span>
                        <span class="ml-auto text-gray-500"><%= if rj[:timestamp], do: Calendar.strftime(rj.timestamp, "%m/%d %H:%M"), else: "" %></span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Status Strip ───────────────────────────────────────────────────────

  defp render_status_strip(assigns) do
    ~H"""
    <div class="flex items-center justify-between bg-gray-800 rounded px-4 py-1.5 text-xs mt-2 mb-1 border border-gray-700">
      <!-- Health dots -->
      <div class="flex items-center gap-2">
        <span class="text-gray-500">Health</span>
        <div class="flex items-center gap-1">
          <%= for {name, status} <- @health[:checks] || %{} do %>
            <div class="flex items-center gap-0.5" title={"#{name}: #{status}"}>
              <div class={"w-2 h-2 rounded-full #{health_dot(status)}"}></div>
              <span class="text-gray-500 text-[10px]"><%= name %></span>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Alerts -->
      <div class="flex items-center gap-1">
        <span class={"#{if length(@alerts) > 0, do: "text-yellow-400", else: "text-gray-500"}"}>
          Alerts: <%= length(@alerts) %> active
        </span>
      </div>

      <!-- Merge Queue -->
      <div class="flex items-center gap-1 text-gray-400">
        <span>MQ: <%= length(@merge_queue[:pending] || []) %> pending</span>
        <%= if active = @merge_queue[:active] do %>
          <span class="text-blue-400">| merging <%= short_id(active[:job_id] || active.job_id) %></span>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp job_pipeline_stages(job, merge_queue) do
    scout =
      cond do
        job[:skip_scout] == true -> :skip
        job[:scout_findings] != nil -> :done
        true -> :skip
      end

    triage =
      case job[:complexity] do
        nil -> :skip
        _ -> :done
      end

    ghost =
      case job[:status] do
        "pending" -> :pending
        "assigned" -> :pending
        "running" -> :active
        "done" -> :done
        "failed" -> :failed
        _ -> :pending
      end

    drone =
      cond do
        job[:skip_verification] == true -> :skip
        job[:verification_status] == "passed" -> :done
        job[:verification_status] == "failed" -> :failed
        job[:verification_status] == "pending" -> :pending
        job[:status] in ["done", "failed"] && !job[:skip_verification] -> :pending
        true -> :skip
      end

    merge =
      cond do
        job[:merged_at] != nil -> :done
        merge_active?(merge_queue, job[:id]) -> :active
        merge_pending?(merge_queue, job[:id]) -> :pending
        merge_completed?(merge_queue, job[:id]) -> :done
        ghost == :done && drone in [:done, :skip] -> :pending
        true -> :skip
      end

    [{"Scout", scout}, {"Triage", triage}, {"Bee", ghost}, {"Drone", drone}, {"Merge", merge}]
  end

  defp merge_active?(%{active: nil}, _job_id), do: false
  defp merge_active?(%{active: active}, job_id), do: (active[:job_id] || active.job_id) == job_id
  defp merge_active?(_, _), do: false

  defp merge_pending?(%{pending: pending}, job_id), do: Enum.any?(pending, fn {jid, _} -> jid == job_id end)
  defp merge_pending?(_, _), do: false

  defp merge_completed?(%{completed: completed}, job_id), do: Enum.any?(completed, fn {jid, _, _} -> jid == job_id end)
  defp merge_completed?(_, _), do: false

  defp stage_badge(:done), do: "bg-green-900 text-green-300"
  defp stage_badge(:active), do: "bg-blue-900 text-blue-300"
  defp stage_badge(:pending), do: "bg-yellow-900 text-yellow-300"
  defp stage_badge(:failed), do: "bg-red-900 text-red-300"
  defp stage_badge(:skip), do: "bg-gray-700 text-gray-500"
  defp stage_badge(_), do: "bg-gray-700 text-gray-500"

  defp complexity_badge("simple"), do: "bg-green-900 text-green-300"
  defp complexity_badge("moderate"), do: "bg-yellow-900 text-yellow-300"
  defp complexity_badge(:simple), do: "bg-green-900 text-green-300"
  defp complexity_badge(:moderate), do: "bg-yellow-900 text-yellow-300"
  defp complexity_badge("complex"), do: "bg-red-900 text-red-300"
  defp complexity_badge(:complex), do: "bg-red-900 text-red-300"
  defp complexity_badge(_), do: "bg-gray-700 text-gray-400"

  defp event_type_badge(type) when type in [:bee_spawned, :bee_completed, :bee_failed, :bee_stopped],
    do: "bg-blue-900 text-blue-300"

  defp event_type_badge(type) when type in [:job_created, :job_transition, :job_verified, :job_rejected],
    do: "bg-yellow-900 text-yellow-300"

  defp event_type_badge(type) when type in [:quest_created, :quest_completed, :quest_failed],
    do: "bg-green-900 text-green-300"

  defp event_type_badge(type) when type in [:merge_started, :merge_succeeded, :merge_failed],
    do: "bg-purple-900 text-purple-300"

  defp event_type_badge(type) when type in [:scout_dispatched, :scout_complete, :drone_verdict],
    do: "bg-cyan-900 text-cyan-300"

  defp event_type_badge(:error), do: "bg-red-900 text-red-300"
  defp event_type_badge(_), do: "bg-gray-700 text-gray-400"

  defp health_dot(:ok), do: "bg-green-500"
  defp health_dot(:warning), do: "bg-yellow-500"
  defp health_dot(:error), do: "bg-red-500"
  defp health_dot(_), do: "bg-gray-500"

  defp merge_outcome_badge(:success), do: "bg-green-900 text-green-300"
  defp merge_outcome_badge(:crash), do: "bg-red-900 text-red-300"
  defp merge_outcome_badge({:failure, _}), do: "bg-red-900 text-red-300"
  defp merge_outcome_badge({:reimagined, _}), do: "bg-yellow-900 text-yellow-300"
  defp merge_outcome_badge(_), do: "bg-gray-700 text-gray-400"

  defp format_outcome(:success), do: "success"
  defp format_outcome(:crash), do: "crash"
  defp format_outcome({:failure, _}), do: "failure"
  defp format_outcome({:reimagined, _}), do: "reimagined"
  defp format_outcome(other), do: to_string(other)

  defp quest_badge("pending"), do: "bg-gray-600 text-gray-300"
  defp quest_badge("active"), do: "bg-blue-900 text-blue-300"
  defp quest_badge("completed"), do: "bg-green-900 text-green-300"
  defp quest_badge("failed"), do: "bg-red-900 text-red-300"
  defp quest_badge(_), do: "bg-gray-600 text-gray-300"

  defp job_badge("pending"), do: "bg-gray-600 text-gray-300"
  defp job_badge("assigned"), do: "bg-yellow-900 text-yellow-300"
  defp job_badge("running"), do: "bg-blue-900 text-blue-300"
  defp job_badge("done"), do: "bg-green-900 text-green-300"
  defp job_badge("failed"), do: "bg-red-900 text-red-300"
  defp job_badge(_), do: "bg-gray-600 text-gray-300"

  defp run_badge("active"), do: "bg-blue-900 text-blue-300"
  defp run_badge("completed"), do: "bg-green-900 text-green-300"
  defp run_badge("failed"), do: "bg-red-900 text-red-300"
  defp run_badge(_), do: "bg-gray-600 text-gray-300"

  defp verification_color("passed"), do: "text-green-400"
  defp verification_color("failed"), do: "text-red-400"
  defp verification_color("pending"), do: "text-yellow-400"
  defp verification_color(_), do: "text-gray-400"

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: to_string(id) |> String.slice(0, 8)

  defp event_summary(%{data: data}) when is_map(data) do
    data
    |> Map.drop([:__struct__])
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp event_summary(_), do: ""

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      _, _ -> default
    end
  end
end
