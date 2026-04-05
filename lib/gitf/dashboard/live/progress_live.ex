defmodule GiTF.Dashboard.ProgressLive do
  @moduledoc "LiveView showing real-time ghost activity feed."

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  require GiTF.Ghost.Status, as: GhostStatus

  @refresh_interval :timer.seconds(2)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, GiTF.Progress.topic())
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info({:bee_progress, _ghost_id, _data}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:waggle_received, _waggle}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    progress_entries = GiTF.Progress.all()
    ghosts = GiTF.Ghosts.list(status: GhostStatus.working())

    # Build a rich view per ghost: progress + ghost metadata + op info
    ghost_activities =
      ghosts
      |> Enum.map(fn ghost ->
        progress = Enum.find(progress_entries, fn e -> e[:ghost_id] == ghost.id end)

        op =
          case ghost[:op_id] do
            nil ->
              nil

            op_id ->
              case GiTF.Ops.get(op_id) do
                {:ok, j} -> j
                _ -> nil
              end
          end

        %{
          ghost_id: ghost.id,
          ghost_name: ghost.name,
          model: ghost[:assigned_model],
          op_id: ghost[:op_id],
          op_title: op && op.title,
          mission_id: op && op.mission_id,
          context_pct: ghost[:context_percentage] || 0.0,
          tool: progress && progress[:tool],
          file: progress && progress[:file],
          message: progress && progress[:message],
          status: ghost.status
        }
      end)
      |> Enum.sort_by(& &1.ghost_name)

    # Recent events from EventStore for the activity log
    recent_events =
      try do
        GiTF.EventStore.list(limit: 15)
        |> Enum.map(fn event ->
          %{
            type: event.type,
            entity_id: event.entity_id,
            timestamp: event.timestamp,
            data: event.data,
            metadata: event.metadata
          }
        end)
      rescue
        _ -> []
      end

    socket
    |> assign(:page_title, "Activity")
    |> assign(:current_path, "/progress")
    |> assign(:ghost_activities, ghost_activities)
    |> assign(:recent_events, recent_events)
    |> assign(:idle_count, length(GiTF.Ghosts.list()) - length(ghosts))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <h1 class="page-title">Factory Activity</h1>

      <!-- Active Ghosts -->
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">
          Active Ghosts ({length(@ghost_activities)})
          <span style="color:#8b949e; font-size:0.8rem; margin-left:0.5rem">
            {if @idle_count > 0, do: "+ #{@idle_count} idle"}
          </span>
        </div>

        <%= if @ghost_activities == [] do %>
          <div class="empty">No ghosts are working right now.</div>
        <% else %>
          <div style="display:flex; flex-direction:column; gap:0.75rem">
            <%= for activity <- @ghost_activities do %>
              <div style="background:#1c2128; border:1px solid #30363d; border-radius:8px; padding:1rem; position:relative; overflow:hidden">
                <!-- Pulse indicator -->
                <div style="position:absolute; top:0; left:0; width:3px; height:100%; background:#3fb950; animation:pulse 2s ease-in-out infinite"></div>

                <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-left:0.75rem">
                  <div style="flex:1">
                    <!-- Ghost identity -->
                    <div style="display:flex; align-items:center; gap:0.5rem; margin-bottom:0.35rem">
                      <% {provider, _short, _tier} = parse_model(activity.model) %>
                      <span class={"model-badge #{provider_class(provider)}"}>{ghost_badge_label(activity.ghost_name, activity.model)}</span>
                      <span style="color:#8b949e; font-size:0.75rem">{short_id(activity.ghost_id)}</span>
                    </div>

                    <!-- What it's working on -->
                    <%= if activity.op_title do %>
                      <div style="color:#c9d1d9; font-size:0.85rem; margin-bottom:0.35rem">
                        <a href={"/dashboard/ops/#{activity.op_id}"} style="color:#58a6ff">{truncate(activity.op_title, 80)}</a>
                      </div>
                    <% end %>

                    <!-- Current action -->
                    <div style="display:flex; align-items:center; gap:0.5rem; color:#8b949e; font-size:0.8rem">
                      <%= if activity.tool do %>
                        <span class="badge badge-purple" style="font-size:0.7rem">{activity.tool}</span>
                      <% end %>
                      <%= if activity.file && activity.file != "" do %>
                        <span style="font-family:monospace; color:#d2a8ff; font-size:0.75rem">{truncate(activity.file, 50)}</span>
                      <% end %>
                      <%= if activity.message do %>
                        <span>{truncate(activity.message, 60)}</span>
                      <% end %>
                    </div>
                  </div>

                  <!-- Context usage -->
                  <div style="text-align:right; min-width:60px">
                    <div style={"font-size:0.75rem; font-weight:600; color:#{context_color(activity.context_pct)}"}>
                      {Float.round(activity.context_pct * 100, 0)}%
                    </div>
                    <div style="width:40px; height:4px; background:#30363d; border-radius:2px; margin-top:2px; margin-left:auto">
                      <div style={"width:#{min(activity.context_pct * 100, 100)}%; height:100%; background:#{context_color(activity.context_pct)}; border-radius:2px"}></div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Recent Events -->
      <div class="panel">
        <div class="panel-title">Recent Events</div>
        <%= if @recent_events == [] do %>
          <div class="empty">No events recorded yet.</div>
        <% else %>
          <div style="display:flex; flex-direction:column; gap:0.25rem">
            <%= for event <- @recent_events do %>
              <div style="display:flex; align-items:center; gap:0.5rem; padding:0.35rem 0; border-bottom:1px solid #21262d; font-size:0.8rem">
                <span class={"badge #{event_badge(event.type)}"} style="font-size:0.65rem; min-width:60px; text-align:center">
                  {format_event_type(event.type)}
                </span>
                <span style="color:#8b949e; font-family:monospace; font-size:0.7rem; min-width:65px">
                  {short_id(event.entity_id)}
                </span>
                <span style="color:#c9d1d9; flex:1">{event_summary(event)}</span>
                <span style="color:#6e7681; font-size:0.7rem">{format_timestamp(event.timestamp)}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.live_component>
    """
  end

  # -- Helpers ---------------------------------------------------------------

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."

  defp context_color(pct) when pct > 0.6, do: "#f85149"
  defp context_color(pct) when pct > 0.4, do: "#d29922"
  defp context_color(_), do: "#3fb950"

  defp event_badge(:bee_spawned), do: "badge-blue"
  defp event_badge(:bee_completed), do: "badge-green"
  defp event_badge(:bee_failed), do: "badge-red"
  defp event_badge(:job_transition), do: "badge-yellow"
  defp event_badge(:merge_succeeded), do: "badge-green"
  defp event_badge(:merge_failed), do: "badge-red"
  defp event_badge(:quest_created), do: "badge-purple"
  defp event_badge(:quest_completed), do: "badge-green"
  defp event_badge(:error), do: "badge-red"
  defp event_badge(_), do: "badge-grey"

  defp format_event_type(:bee_spawned), do: "spawned"
  defp format_event_type(:bee_completed), do: "completed"
  defp format_event_type(:bee_failed), do: "failed"
  defp format_event_type(:bee_stopped), do: "stopped"
  defp format_event_type(:job_transition), do: "op"
  defp format_event_type(:quest_created), do: "mission"
  defp format_event_type(:quest_completed), do: "mission"
  defp format_event_type(:merge_succeeded), do: "merged"
  defp format_event_type(:merge_failed), do: "merge fail"
  defp format_event_type(:error), do: "error"
  defp format_event_type(type), do: type |> to_string() |> String.replace("_", " ")

  defp event_summary(%{type: :bee_failed, data: data}) do
    step = Map.get(data, :step) || Map.get(data, "step")
    reason = Map.get(data, :reason) || Map.get(data, :error) || Map.get(data, "error")
    parts = [step && "at #{step}", reason && truncate(inspect(reason), 60)]
    Enum.reject(parts, &is_nil/1) |> Enum.join(" — ")
  end

  defp event_summary(%{type: :job_transition, data: data}) do
    action = Map.get(data, :action) || Map.get(data, "action")
    "op #{action}"
  end

  defp event_summary(%{type: :quest_created, data: data}) do
    Map.get(data, :name) || Map.get(data, "name") || "created"
  end

  defp event_summary(%{type: :error, data: data}) do
    Map.get(data, :message) || Map.get(data, "message") ||
      inspect(data)
      |> truncate(80)
  end

  defp event_summary(%{data: data}) when map_size(data) > 0 do
    data |> inspect() |> truncate(80)
  end

  defp event_summary(_), do: ""
end
