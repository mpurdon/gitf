defmodule GiTF.Dashboard.GhostsLive do
  @moduledoc """
  Ghost monitoring page.

  Displays all ghosts with their status, name, assigned op, and shell
  information. Subscribes to PubSub for live status updates. Working
  ghosts show a green pulse animation; crashed ghosts appear in red.
  """

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  require GiTF.Ghost.Status, as: GhostStatus

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
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

  @impl true
  def handle_event("toggle", %{"id" => ghost_id}, socket) do
    expanded = Map.get(socket.assigns, :expanded, MapSet.new())

    expanded =
      if MapSet.member?(expanded, ghost_id),
        do: MapSet.delete(expanded, ghost_id),
        else: MapSet.put(expanded, ghost_id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("stop", %{"id" => ghost_id}, socket) do
    case GiTF.Ghosts.stop(ghost_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Ghost stopped.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  defp assign_data(socket) do
    ghosts = GiTF.Ghosts.list()

    socket
    |> assign(:page_title, "Ghosts")
    |> assign(:current_path, "/ghosts")
    |> assign(:ghosts, ghosts)
    |> Map.put_new(:expanded, MapSet.new())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <h1 class="page-title">Ghost Agents</h1>

      <div class="panel">
        <%= if @ghosts == [] do %>
          <div class="empty">No ghosts deployed yet. Ghosts are created when the Major assigns ops.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th></th>
                <th>ID</th>
                <th>Ghost</th>
                <th>Status</th>
                <th>Job ID</th>
                <th>Context</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for ghost <- @ghosts do %>
                <tr class="detail-toggle" phx-click="toggle" phx-value-id={ghost.id}>
                  <td style="width:1.5rem">{if MapSet.member?(Map.get(assigns, :expanded, MapSet.new()), ghost.id), do: "v", else: ">"}</td>
                  <td style="width:1rem">
                    <span style={"display:inline-block; width:8px; height:8px; border-radius:50%; background:#{status_dot_color(Map.get(ghost, :status, "unknown"))}"} class={if Map.get(ghost, :status) == GhostStatus.working(), do: "pulse"}></span>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem">{short_id(ghost.id)}</td>
                  <td>
                    <% {provider, _short, _tier} = parse_model(Map.get(ghost, :assigned_model)) %>
                    <span class={"model-badge #{provider_class(provider)}"}>{ghost_badge_label(Map.get(ghost, :name, "-"), ghost[:assigned_model])}</span>
                  </td>
                  <td><span class={"badge #{status_badge(Map.get(ghost, :status, "unknown"))}"}>{Map.get(ghost, :status, "unknown")}</span></td>
                  <td style="font-family:monospace; font-size:0.8rem">
                    <%= if Map.get(ghost, :op_id) do %>
                      <a href={"/dashboard/ops/#{ghost.op_id}"}>{short_id(ghost.op_id)}</a>
                    <% else %>
                      -
                    <% end %>
                  </td>
                  <td>
                    <%= if Map.has_key?(ghost, :context_percentage) do %>
                      <span class={"badge #{context_badge(ghost.context_percentage)}"}>
                        {Float.round(ghost.context_percentage / 1, 1)}%
                      </span>
                    <% else %>
                      <span class="badge badge-grey">-</span>
                    <% end %>
                  </td>
                  <td>
                    <%= if Map.get(ghost, :status) == GhostStatus.working() do %>
                      <button phx-click="stop" phx-value-id={ghost.id} class="btn btn-red" style="padding:0.2rem 0.6rem; font-size:0.75rem">
                        Stop
                      </button>
                    <% end %>
                  </td>
                </tr>
                <%= if MapSet.member?(Map.get(assigns, :expanded, MapSet.new()), ghost.id) do %>
                  <tr>
                    <td colspan="9" style="padding:0">
                      <div class="detail-content">
                        <dl class="metadata-grid">
                          <dt>Full ID</dt><dd style="font-family:monospace; font-size:0.8rem">{ghost.id}</dd>
                          <dt>Shell</dt><dd style="font-family:monospace; font-size:0.8rem">{Map.get(ghost, :shell_path, "-")}</dd>
                          <dt>Model</dt><dd>{Map.get(ghost, :assigned_model, "-")}</dd>
                          <dt>Op</dt>
                          <dd>
                            <%= if Map.get(ghost, :op_id) do %>
                              <a href={"/dashboard/ops/#{ghost.op_id}"} style="font-family:monospace; font-size:0.8rem">{ghost.op_id}</a>
                            <% else %>
                              -
                            <% end %>
                          </dd>
                          <dt>Context</dt>
                          <dd>
                            <%= if Map.has_key?(ghost, :context_percentage) do %>
                              <div class="cost-bar" style="width:120px; margin-top:0.25rem">
                                <div class="cost-bar-fill" style={"width:#{min(ghost.context_percentage, 100)}%; background:#{if ghost.context_percentage > 40, do: "#f85149", else: "#3fb950"}"}></div>
                              </div>
                              <span style="font-size:0.8rem">{Float.round(ghost.context_percentage / 1, 1)}%</span>
                            <% else %>
                              -
                            <% end %>
                          </dd>
                        </dl>
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

  defp status_dot_color(GhostStatus.working()), do: "#3fb950"
  defp status_dot_color(GhostStatus.starting()), do: "#58a6ff"
  defp status_dot_color(GhostStatus.idle()), do: "#8b949e"
  defp status_dot_color("paused"), do: "#d29922"
  defp status_dot_color(GhostStatus.stopped()), do: "#484f58"
  defp status_dot_color(GhostStatus.crashed()), do: "#f85149"
  defp status_dot_color(_), do: "#484f58"
  
  defp context_badge(percentage) when percentage >= 45, do: "badge-red"
  defp context_badge(percentage) when percentage >= 40, do: "badge-yellow"
  defp context_badge(_), do: "badge-green"
end
