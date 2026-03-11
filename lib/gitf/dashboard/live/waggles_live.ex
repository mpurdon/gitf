defmodule GiTF.Dashboard.WagglesLive do
  @moduledoc """
  Waggle message viewer.

  Lists recent inter-agent messages in reverse chronological order.
  Auto-updates when new waggles arrive via PubSub subscription, so the
  operator sees real-time message flow without refreshing.
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
    end

    waggles = GiTF.Waggle.list(limit: 50)

    {:ok,
     socket
     |> assign(:page_title, "Waggles")
     |> assign(:current_path, "/waggles")
     |> assign(:waggles, waggles)}
  end

  @impl true
  def handle_info({:waggle_received, _waggle}, socket) do
    waggles = GiTF.Waggle.list(limit: 50)
    {:noreply, assign(socket, :waggles, waggles)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    waggles = GiTF.Waggle.list(limit: 50)
    {:noreply, assign(socket, :waggles, waggles)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Waggle Messages</h1>
        <button phx-click="refresh" style="background:#1f6feb33; color:#58a6ff; border:1px solid #1f6feb55; padding:0.4rem 1rem; border-radius:6px; cursor:pointer; font-size:0.85rem">
          Refresh
        </button>
      </div>

      <div class="panel">
        <%= if @waggles == [] do %>
          <div class="empty">No waggle messages found. Messages appear here as ghosts and the Major communicate.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th>From</th>
                <th>To</th>
                <th>Subject</th>
                <th>Time</th>
              </tr>
            </thead>
            <tbody>
              <%= for waggle <- @waggles do %>
                <tr class={unless waggle.read, do: "waggle-unread"}>
                  <td style="width:1rem">
                    <span class={"badge #{if waggle.read, do: "badge-grey", else: "badge-blue"}"} style="font-size:0.65rem">
                      {if waggle.read, do: "R", else: "N"}
                    </span>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem">{waggle.from}</td>
                  <td style="font-family:monospace; font-size:0.8rem">{waggle.to}</td>
                  <td class={unless waggle.read, do: "waggle-subject"}>{waggle.subject || "(no subject)"}</td>
                  <td style="font-size:0.8rem; color:#8b949e">{format_timestamp(waggle.inserted_at)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_), do: "-"
end
