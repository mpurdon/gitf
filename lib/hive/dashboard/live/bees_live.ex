defmodule Hive.Dashboard.BeesLive do
  @moduledoc """
  Bee monitoring page.

  Displays all bees with their status, name, assigned job, and cell
  information. Subscribes to PubSub for live status updates. Working
  bees show a green pulse animation; crashed bees appear in red.
  """

  use Phoenix.LiveView

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "waggle:queen")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info({:waggle_received, _waggle}, socket) do
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    bees = Hive.Bees.list()

    socket
    |> assign(:page_title, "Bees")
    |> assign(:current_path, "/bees")
    |> assign(:bees, bees)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={Hive.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <h1 class="page-title">Bee Agents</h1>

      <div class="panel">
        <%= if @bees == [] do %>
          <div class="empty">No bees spawned yet. Bees are created when the Queen assigns jobs.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th>ID</th>
                <th>Name</th>
                <th>Status</th>
                <th>Job ID</th>
                <th>Model</th>
                <th>Context</th>
              </tr>
            </thead>
            <tbody>
              <%= for bee <- @bees do %>
                <tr>
                  <td style="width:1rem">
                    <span style={"display:inline-block; width:8px; height:8px; border-radius:50%; background:#{status_dot_color(bee.status)}"} class={if bee.status == "working", do: "pulse"}></span>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem">{bee.id}</td>
                  <td>{bee.name}</td>
                  <td><span class={"badge #{status_badge(bee.status)}"}>{bee.status}</span></td>
                  <td style="font-family:monospace; font-size:0.8rem">{bee.job_id || "-"}</td>
                  <td style="font-size:0.8rem">{Map.get(bee, :assigned_model, "-")}</td>
                  <td>
                    <%= if Map.has_key?(bee, :context_percentage) do %>
                      <span class={"badge #{context_badge(bee.context_percentage)}"}>
                        {Float.round(bee.context_percentage / 1, 1)}%
                      </span>
                    <% else %>
                      <span class="badge badge-grey">-</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end

  defp status_badge("working"), do: "badge-green"
  defp status_badge("starting"), do: "badge-blue"
  defp status_badge("idle"), do: "badge-grey"
  defp status_badge("paused"), do: "badge-yellow"
  defp status_badge("stopped"), do: "badge-grey"
  defp status_badge("crashed"), do: "badge-red"
  defp status_badge(_), do: "badge-grey"

  defp status_dot_color("working"), do: "#3fb950"
  defp status_dot_color("starting"), do: "#58a6ff"
  defp status_dot_color("idle"), do: "#8b949e"
  defp status_dot_color("paused"), do: "#d29922"
  defp status_dot_color("stopped"), do: "#484f58"
  defp status_dot_color("crashed"), do: "#f85149"
  defp status_dot_color(_), do: "#484f58"
  
  defp context_badge(percentage) when percentage >= 45, do: "badge-red"
  defp context_badge(percentage) when percentage >= 40, do: "badge-yellow"
  defp context_badge(_), do: "badge-green"
end
