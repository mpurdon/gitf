defmodule GiTF.Dashboard.TimelineLive do
  @moduledoc """
  Factory-wide event timeline showing phase transitions, op events,
  ghost activity, alerts, and approvals in chronological order.

  Supports filtering by mission and event type.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(15)
  @max_events 200

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "ops")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "costs")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    mission_id = params["mission_id"]

    {:ok,
     socket
     |> assign(:mission_id, mission_id)
     |> assign(:filter_type, "all")
     |> init_toasts()
     |> stream_events()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, stream_events(socket)}
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> stream_events()}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:filter_type, type)
     |> stream_events()}
  end

  def handle_event("filter_mission", %{"mission_id" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:mission_id, nil)
     |> stream_events()}
  end

  def handle_event("filter_mission", %{"mission_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:mission_id, id)
     |> stream_events()}
  end

  defp stream_events(socket) do
    mission_id = socket.assigns.mission_id
    filter_type = socket.assigns.filter_type

    events = gather_events(mission_id, filter_type)
    missions = GiTF.Missions.list() |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})

    mission_name =
      case mission_id do
        nil ->
          nil

        id ->
          case GiTF.Archive.get(:missions, id) do
            nil -> nil
            m -> Map.get(m, :name, short_id(id))
          end
      end

    socket
    |> assign(:page_title, "Timeline")
    |> assign(:current_path, "/timeline")
    |> assign(:events, events)
    |> assign(:missions, missions)
    |> assign(:mission_name, mission_name)
    |> assign(:event_count, length(events))
  end

  # Gathers events from multiple sources into a unified timeline
  defp gather_events(mission_id, filter_type) do
    events =
      []
      |> maybe_add(filter_type, "all", "transitions", &phase_transition_events(mission_id, &1))
      |> maybe_add(filter_type, "all", "ops", &op_events(mission_id, &1))
      |> maybe_add(filter_type, "all", "links", &link_events(mission_id, &1))
      |> maybe_add(filter_type, "all", "approvals", &approval_events(mission_id, &1))

    events
    |> List.flatten()
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(@max_events)
  end

  defp maybe_add(acc, current, match_all, type, fun) do
    if current == match_all or current == type do
      [fun.(acc) | acc]
    else
      acc
    end
  end

  defp phase_transition_events(mission_id, _acc) do
    transitions =
      case mission_id do
        nil ->
          GiTF.Archive.all(:mission_phase_transitions)

        id ->
          GiTF.Archive.filter(:mission_phase_transitions, &(&1[:mission_id] == id))
      end

    Enum.map(transitions, fn t ->
      %{
        type: :phase_transition,
        icon: "arrow-right",
        color: "#8b5cf6",
        title: "Phase: #{t[:from_phase] || "?"} → #{t[:to_phase] || "?"}",
        detail: t[:reason],
        mission_id: t[:mission_id],
        timestamp: t[:transitioned_at] || t[:inserted_at] || DateTime.utc_now()
      }
    end)
  end

  defp op_events(mission_id, _acc) do
    ops =
      case mission_id do
        nil ->
          GiTF.Archive.all(:ops)

        id ->
          GiTF.Archive.filter(:ops, &(&1[:mission_id] == id))
      end

    ops
    |> Enum.filter(&(&1.status in ["done", "failed", "running"]))
    |> Enum.map(fn op ->
      %{
        type: :op_event,
        icon: op_icon(op.status),
        color: op_color(op.status),
        title: "Op #{op.status}: #{op.title || short_id(op.id)}",
        detail:
          case op.status do
            "failed" -> Map.get(op, :error_message)
            "done" -> "verified: #{Map.get(op, :verification_status, "pending")}"
            _ -> nil
          end,
        mission_id: op.mission_id,
        op_id: op.id,
        timestamp: op[:updated_at] || op[:inserted_at] || DateTime.utc_now()
      }
    end)
  end

  defp link_events(mission_id, _acc) do
    links =
      case mission_id do
        nil ->
          GiTF.Link.list(limit: 100)

        _id ->
          # Links don't carry mission_id directly — show all recent for now
          GiTF.Link.list(limit: 50)
      end

    links
    |> Enum.filter(
      &(&1.subject in ~w(job_complete job_failed quest_advance human_approval merge_failed pr_created))
    )
    |> Enum.map(fn link ->
      %{
        type: :link,
        icon: "chat",
        color: "#58a6ff",
        title: "#{link.subject}: #{link.from} → #{link.to}",
        detail: String.slice(link.body || "", 0, 120),
        mission_id: nil,
        timestamp: link.inserted_at
      }
    end)
  end

  defp approval_events(mission_id, _acc) do
    requests =
      case mission_id do
        nil ->
          GiTF.Archive.all(:approval_requests)

        id ->
          GiTF.Archive.filter(:approval_requests, &(&1[:mission_id] == id))
      end

    Enum.map(requests, fn req ->
      %{
        type: :approval,
        icon: "shield",
        color:
          case req.status do
            "approved" -> "#3fb950"
            "rejected" -> "#f85149"
            _ -> "#d29922"
          end,
        title: "Approval #{req.status}: #{Map.get(req, :quest_name, short_id(req.mission_id))}",
        detail:
          case req[:decided_by] do
            nil -> nil
            by -> "by #{by}"
          end,
        mission_id: req.mission_id,
        timestamp: req[:decided_at] || req[:requested_at] || DateTime.utc_now()
      }
    end)
  end

  defp op_icon("done"), do: "check"
  defp op_icon("failed"), do: "x"
  defp op_icon("running"), do: "play"
  defp op_icon(_), do: "dot"

  defp op_color("done"), do: "#3fb950"
  defp op_color("failed"), do: "#f85149"
  defp op_color("running"), do: "#3b82f6"
  defp op_color(_), do: "#6b7280"

  defp event_type_label(:phase_transition), do: "Phase"
  defp event_type_label(:op_event), do: "Op"
  defp event_type_label(:link), do: "Link"
  defp event_type_label(:approval), do: "Approval"
  defp event_type_label(_), do: "Event"

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">
          Factory Timeline
          <%= if @mission_name do %>
            <span style="color:#6b7280; font-size:0.8rem; font-weight:400"> &mdash; {@mission_name}</span>
          <% end %>
        </h1>
        <span style="color:#6b7280; font-size:0.8rem">{@event_count} events</span>
      </div>

      <%!-- Filters --%>
      <div style="display:flex; gap:1rem; margin-bottom:1rem; align-items:center; flex-wrap:wrap">
        <%!-- Type filter --%>
        <div style="display:flex; gap:0.25rem">
          <%= for {label, key} <- [{"All", "all"}, {"Phases", "transitions"}, {"Ops", "ops"}, {"Links", "links"}, {"Approvals", "approvals"}] do %>
            <button
              phx-click="filter_type"
              phx-value-type={key}
              class={"btn #{if @filter_type == key, do: "btn-blue", else: "btn-grey"}"}
              style="font-size:0.75rem; padding:0.25rem 0.5rem"
            >
              {label}
            </button>
          <% end %>
        </div>

        <%!-- Mission filter --%>
        <form phx-change="filter_mission" style="display:flex; align-items:center; gap:0.5rem">
          <label style="font-size:0.8rem; color:#6b7280">Mission:</label>
          <select name="mission_id" class="form-input" style="font-size:0.8rem; padding:0.25rem 0.5rem; max-width:250px">
            <option value="">All missions</option>
            <%= for m <- @missions do %>
              <option value={m.id} selected={m.id == @mission_id}>
                {Map.get(m, :name) || String.slice(Map.get(m, :goal, ""), 0, 40)}
              </option>
            <% end %>
          </select>
        </form>
      </div>

      <%!-- Timeline --%>
      <div class="panel">
        <%= if @events == [] do %>
          <div class="empty">No events to display. Events appear as missions run through phases, ops complete, and the factory operates. <a href="/dashboard/missions/new" style="color:#58a6ff">Create a mission</a> to get started.</div>
        <% else %>
          <div style="position:relative; padding-left:2rem">
            <%!-- Vertical line --%>
            <div style="position:absolute; left:0.75rem; top:0; bottom:0; width:2px; background:#21262d"></div>

            <%= for event <- @events do %>
              <div style="position:relative; padding-bottom:1rem; padding-left:1.5rem">
                <%!-- Dot on the timeline --%>
                <div style={"position:absolute; left:-0.55rem; top:0.3rem; width:10px; height:10px; border-radius:50%; background:#{event.color}; border:2px solid #0d1117"}></div>

                <div style="display:flex; justify-content:space-between; align-items:flex-start">
                  <div style="flex:1">
                    <div style="display:flex; align-items:center; gap:0.5rem; margin-bottom:0.15rem">
                      <span class={"badge #{case event.type do
                        :phase_transition -> "badge-purple"
                        :op_event -> "badge-blue"
                        :link -> "badge-grey"
                        :approval -> "badge-yellow"
                        _ -> "badge-grey"
                      end}"} style="font-size:0.6rem">
                        {event_type_label(event.type)}
                      </span>
                      <span style="color:#f0f6fc; font-size:0.85rem; font-weight:500">{event.title}</span>
                    </div>
                    <%= if event.detail do %>
                      <div style="color:#8b949e; font-size:0.8rem; margin-top:0.1rem; max-width:600px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap">
                        {event.detail}
                      </div>
                    <% end %>
                    <div style="display:flex; gap:0.5rem; margin-top:0.2rem">
                      <%= if event[:mission_id] do %>
                        <a href={"/dashboard/missions/#{event.mission_id}"} style="color:#58a6ff; font-size:0.7rem">
                          mission:{short_id(event.mission_id)}
                        </a>
                      <% end %>
                      <%= if event[:op_id] do %>
                        <a href={"/dashboard/ops/#{event.op_id}"} style="color:#58a6ff; font-size:0.7rem">
                          op:{short_id(event.op_id)}
                        </a>
                      <% end %>
                    </div>
                  </div>
                  <span style="color:#6b7280; font-size:0.75rem; white-space:nowrap; margin-left:1rem">
                    <span title={format_timestamp(event.timestamp)}>{relative_time(event.timestamp)}</span>
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.live_component>
    """
  end
end
