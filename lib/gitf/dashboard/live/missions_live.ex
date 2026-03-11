defmodule GiTF.Dashboard.MissionsLive do
  @moduledoc """
  Quest management page.

  Displays all missions in a table with status badges. Quests can be
  expanded to reveal their constituent ops. Status colors provide
  visual feedback: green for completed, blue for active, grey for
  pending, red for failed.
  """

  use Phoenix.LiveView

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    missions = load_quests()

    {:ok,
     socket
     |> assign(:page_title, "Quests")
     |> assign(:current_path, "/missions")
     |> assign(:missions, missions)
     |> assign(:expanded, MapSet.new())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, :missions, load_quests())}
  end

  def handle_info({:waggle_received, _waggle}, socket) do
    {:noreply, assign(socket, :missions, load_quests())}
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
    {:noreply, assign(socket, :missions, load_quests())}
  end

  defp load_quests do
    GiTF.Missions.list()
    |> Enum.map(fn mission ->
      case GiTF.Missions.get(mission.id) do
        {:ok, q} -> q
        _ -> mission
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Quests</h1>
        <button phx-click="refresh" style="background:#1f6feb33; color:#58a6ff; border:1px solid #1f6feb55; padding:0.4rem 1rem; border-radius:6px; cursor:pointer; font-size:0.85rem">
          Refresh
        </button>
      </div>

      <div class="panel">
        <%= if @missions == [] do %>
          <div class="empty">No missions created yet. Use <code>hive mission new &lt;name&gt;</code> to create one.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th>ID</th>
                <th>Name</th>
                <th>Status</th>
                <th>Phase</th>
                <th>Jobs</th>
              </tr>
            </thead>
            <tbody>
              <%= for mission <- @missions do %>
                <tr class="detail-toggle" phx-click="toggle" phx-value-id={mission.id}>
                  <td style="width:1.5rem">{if MapSet.member?(@expanded, mission.id), do: "v", else: ">"}</td>
                  <td style="font-family:monospace; font-size:0.8rem">{mission.id}</td>
                  <td>{Map.get(mission, :name, mission.goal)}</td>
                  <td><span class={"badge #{status_badge(Map.get(mission, :status, "unknown"))}"}>{Map.get(mission, :status, "unknown")}</span></td>
                  <td><span class={"badge #{phase_badge(Map.get(mission, :current_phase, "pending"))}"}>
                    {Map.get(mission, :current_phase, "pending")}
                  </span></td>
                  <td>{job_count(mission)}</td>
                </tr>
                <%= if MapSet.member?(@expanded, mission.id) do %>
                  <tr>
                    <td colspan="6" style="padding:0">
                      <div class="detail-content">
                        <%= if has_jobs?(mission) do %>
                          <table>
                            <thead>
                              <tr>
                                <th>Job ID</th>
                                <th>Title</th>
                                <th>Status</th>
                                <th>Audit</th>
                                <th>Bee ID</th>
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
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end

  defp status_badge("completed"), do: "badge-green"
  defp status_badge("done"), do: "badge-green"
  defp status_badge("active"), do: "badge-blue"
  defp status_badge("running"), do: "badge-blue"
  defp status_badge("assigned"), do: "badge-blue"
  defp status_badge("failed"), do: "badge-red"
  defp status_badge("blocked"), do: "badge-yellow"
  defp status_badge("pending"), do: "badge-grey"
  defp status_badge(_), do: "badge-grey"
  
  defp phase_badge("research"), do: "badge-blue"
  defp phase_badge("planning"), do: "badge-yellow"
  defp phase_badge("implementation"), do: "badge-purple"
  defp phase_badge("completed"), do: "badge-green"
  defp phase_badge(_), do: "badge-grey"
  
  defp verification_badge("passed"), do: "badge-green"
  defp verification_badge("failed"), do: "badge-red"
  defp verification_badge("pending"), do: "badge-yellow"
  defp verification_badge(_), do: "badge-grey"

  defp has_jobs?(%{ops: ops}) when is_list(ops), do: ops != []
  defp has_jobs?(_), do: false

  defp job_count(%{ops: ops}) when is_list(ops), do: "#{length(ops)}"
  defp job_count(_), do: "-"
end
