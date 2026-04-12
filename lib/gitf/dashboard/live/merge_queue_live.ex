defmodule GiTF.Dashboard.MergeQueueLive do
  @moduledoc """
  Merge queue visualization showing pending, active, and recent merges.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "sync:queue")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    {:ok, socket |> init_toasts() |> assign_data()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, assign_data(socket)}
  end

  # React to merge queue changes and waggle messages in real-time
  def handle_info({:waggle_received, waggle}, socket) do
    {:noreply, socket |> maybe_apply_toast(waggle) |> assign_data()}
  end

  def handle_info({:sync_queue_updated, _}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    queue_status =
      try do
        GiTF.Sync.Queue.status()
      rescue
        _ -> %{pending: [], active: nil, completed: []}
      end

    pending =
      (queue_status[:pending] || [])
      |> Enum.map(fn
        {op_id, shell_id} -> enrich_merge_entry(op_id, shell_id, "pending")
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    active =
      case queue_status[:active] do
        {op_id, shell_id, _ref} -> enrich_merge_entry(op_id, shell_id, "merging")
        {op_id, shell_id} -> enrich_merge_entry(op_id, shell_id, "merging")
        _ -> nil
      end

    completed =
      (queue_status[:completed] || [])
      |> Enum.take(20)
      |> Enum.map(fn
        {op_id, outcome, ts} ->
          entry = enrich_merge_entry(op_id, nil, "completed")
          Map.merge(entry, %{outcome: outcome, completed_at: ts})

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    socket
    |> assign(:page_title, "Merge Queue")
    |> assign(:current_path, "/merges")
    |> assign(:pending, pending)
    |> assign(:active, active)
    |> assign(:completed, completed)
    |> assign(:pending_count, length(pending))
  end

  defp enrich_merge_entry(op_id, shell_id, status) do
    op = GiTF.Archive.get(:ops, op_id)

    mission =
      case op do
        %{mission_id: mid} -> GiTF.Archive.get(:missions, mid)
        _ -> nil
      end

    %{
      op_id: op_id,
      shell_id: shell_id,
      status: status,
      op_title: op && op[:title],
      mission_name: mission && (mission[:name] || short_id(mission.id)),
      mission_id: op && op[:mission_id]
    }
  rescue
    _ -> %{op_id: op_id, shell_id: shell_id, status: status, op_title: nil, mission_name: nil, mission_id: nil}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">Merge Queue</h1>
        <span style="color:#6b7280; font-size:0.85rem">{@pending_count} pending</span>
      </div>

      <%!-- Active merge --%>
      <div class="panel" style="margin-bottom:1rem">
        <div class="panel-title">Currently Merging</div>
        <%= if @active do %>
          <div style="display:flex; align-items:center; gap:0.75rem; padding:0.5rem 0">
            <div class="loading-spinner" style="width:16px; height:16px; border-width:2px"></div>
            <div>
              <a href={"/dashboard/ops/#{@active.op_id}"} style="color:#58a6ff; font-size:0.9rem">
                {@active.op_title || short_id(@active.op_id)}
              </a>
              <%= if @active.mission_name do %>
                <span style="color:#6b7280; font-size:0.8rem"> &mdash;
                  <a href={"/dashboard/missions/#{@active.mission_id}"} style="color:#8b949e">{@active.mission_name}</a>
                </span>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="empty" style="padding:0.5rem 0">No active merge</div>
        <% end %>
      </div>

      <%!-- Pending --%>
      <div class="panel" style="margin-bottom:1rem">
        <div class="panel-title">Pending ({length(@pending)})</div>
        <%= if @pending == [] do %>
          <div class="empty" style="padding:0.5rem 0">Queue is empty</div>
        <% else %>
          <table class="table" style="width:100%">
            <thead><tr><th>#</th><th>Op</th><th>Mission</th><th>Shell</th></tr></thead>
            <tbody>
              <%= for {entry, idx} <- Enum.with_index(@pending) do %>
                <tr>
                  <td style="color:#6b7280">{idx + 1}</td>
                  <td>
                    <a href={"/dashboard/ops/#{entry.op_id}"} style="color:#58a6ff; font-size:0.85rem">
                      {entry.op_title || short_id(entry.op_id)}
                    </a>
                  </td>
                  <td>
                    <%= if entry.mission_id do %>
                      <a href={"/dashboard/missions/#{entry.mission_id}"} style="color:#8b949e; font-size:0.8rem">{entry.mission_name}</a>
                    <% else %>
                      <span style="color:#6b7280">-</span>
                    <% end %>
                  </td>
                  <td style="font-family:monospace; font-size:0.75rem; color:#8b949e">{short_id(entry.shell_id || "-")}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>

      <%!-- Recent completed --%>
      <div class="panel">
        <div class="panel-title">Recent Merges</div>
        <%= if @completed == [] do %>
          <div class="empty" style="padding:0.5rem 0">No completed merges yet</div>
        <% else %>
          <table class="table" style="width:100%">
            <thead><tr><th>Op</th><th>Mission</th><th>Outcome</th><th>Completed</th></tr></thead>
            <tbody>
              <%= for entry <- @completed do %>
                <tr>
                  <td>
                    <a href={"/dashboard/ops/#{entry.op_id}"} style="color:#58a6ff; font-size:0.85rem">
                      {entry.op_title || short_id(entry.op_id)}
                    </a>
                  </td>
                  <td>
                    <%= if entry.mission_id do %>
                      <a href={"/dashboard/missions/#{entry.mission_id}"} style="color:#8b949e; font-size:0.8rem">{entry.mission_name}</a>
                    <% end %>
                  </td>
                  <td>
                    <span class={"badge #{case entry[:outcome] do
                      :ok -> "badge-green"
                      :error -> "badge-red"
                      _ -> "badge-grey"
                    end}"}>{entry[:outcome] || "?"}</span>
                  </td>
                  <td style="font-size:0.8rem; color:#8b949e">{format_timestamp(entry[:completed_at])}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end
end
