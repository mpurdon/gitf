defmodule Hive.Dashboard.QuestsLive do
  @moduledoc """
  Quest management page.

  Displays all quests in a table with status badges. Quests can be
  expanded to reveal their constituent jobs. Status colors provide
  visual feedback: green for completed, blue for active, grey for
  pending, red for failed.
  """

  use Phoenix.LiveView

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hive.PubSub, "waggle:queen")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    quests = load_quests()

    {:ok,
     socket
     |> assign(:page_title, "Quests")
     |> assign(:current_path, "/quests")
     |> assign(:quests, quests)
     |> assign(:expanded, MapSet.new())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, :quests, load_quests())}
  end

  def handle_info({:waggle_received, _waggle}, socket) do
    {:noreply, assign(socket, :quests, load_quests())}
  end

  @impl true
  def handle_event("toggle", %{"id" => quest_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, quest_id) do
        MapSet.delete(socket.assigns.expanded, quest_id)
      else
        MapSet.put(socket.assigns.expanded, quest_id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :quests, load_quests())}
  end

  defp load_quests do
    Hive.Quests.list()
    |> Enum.map(fn quest ->
      case Hive.Quests.get(quest.id) do
        {:ok, q} -> q
        _ -> quest
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={Hive.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Quests</h1>
        <button phx-click="refresh" style="background:#1f6feb33; color:#58a6ff; border:1px solid #1f6feb55; padding:0.4rem 1rem; border-radius:6px; cursor:pointer; font-size:0.85rem">
          Refresh
        </button>
      </div>

      <div class="panel">
        <%= if @quests == [] do %>
          <div class="empty">No quests created yet. Use <code>hive quest new &lt;name&gt;</code> to create one.</div>
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
              <%= for quest <- @quests do %>
                <tr class="detail-toggle" phx-click="toggle" phx-value-id={quest.id}>
                  <td style="width:1.5rem">{if MapSet.member?(@expanded, quest.id), do: "v", else: ">"}</td>
                  <td style="font-family:monospace; font-size:0.8rem">{quest.id}</td>
                  <td>{quest.name}</td>
                  <td><span class={"badge #{status_badge(quest.status)}"}>{quest.status}</span></td>
                  <td><span class={"badge #{phase_badge(Map.get(quest, :current_phase, "pending"))}"}>
                    {Map.get(quest, :current_phase, "pending")}
                  </span></td>
                  <td>{job_count(quest)}</td>
                </tr>
                <%= if MapSet.member?(@expanded, quest.id) do %>
                  <tr>
                    <td colspan="6" style="padding:0">
                      <div class="detail-content">
                        <%= if has_jobs?(quest) do %>
                          <table>
                            <thead>
                              <tr>
                                <th>Job ID</th>
                                <th>Title</th>
                                <th>Status</th>
                                <th>Verification</th>
                                <th>Bee ID</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for job <- quest.jobs do %>
                                <tr>
                                  <td style="font-family:monospace; font-size:0.8rem">{job.id}</td>
                                  <td>{job.title}</td>
                                  <td><span class={"badge #{status_badge(job.status)}"}>{job.status}</span></td>
                                  <td>
                                    <%= if Map.get(job, :verification_status) do %>
                                      <span class={"badge #{verification_badge(job.verification_status)}"}>
                                        {job.verification_status}
                                      </span>
                                    <% else %>
                                      <span class="badge badge-grey">-</span>
                                    <% end %>
                                  </td>
                                  <td style="font-family:monospace; font-size:0.8rem">{job.bee_id || "-"}</td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        <% else %>
                          <div class="empty" style="text-align:left">No jobs in this quest.</div>
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

  defp has_jobs?(%{jobs: jobs}) when is_list(jobs), do: jobs != []
  defp has_jobs?(_), do: false

  defp job_count(%{jobs: jobs}) when is_list(jobs), do: "#{length(jobs)}"
  defp job_count(_), do: "-"
end
