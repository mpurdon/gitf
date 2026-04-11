defmodule GiTF.Dashboard.HealthLive do
  @moduledoc """
  System health dashboard showing health checks, active alerts,
  alert history, and factory scaling status.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import Phoenix.HTML, only: [raw: 1]

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok, socket |> init_toasts() |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("run_self_heal", _params, socket) do
    results = GiTF.Autonomy.self_heal()

    msg =
      case results do
        [] -> "No issues found"
        items -> "Fixed #{length(items)} issue(s): #{inspect(items)}"
      end

    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> assign_data()}
  end

  defp assign_data(socket) do
    health = GiTF.Observability.Health.check()
    alerts = GiTF.Observability.Alerts.check_alerts()
    alive = GiTF.Observability.Health.alive?()
    ready = GiTF.Observability.Health.ready?()

    # Scaling status
    scaling =
      try do
        status = GiTF.Major.status()

        %{
          max_ghosts: Map.get(status, :max_ghosts, "?"),
          effective_max: Map.get(status, :effective_max_ghosts, "?"),
          active_ghosts: map_size(Map.get(status, :active_ghosts, %{}))
        }
      rescue
        _ -> %{max_ghosts: "?", effective_max: "?", active_ghosts: 0}
      end

    budget_util =
      try do
        Float.round(GiTF.Autonomy.max_budget_utilization() * 100, 1)
      rescue
        _ -> 0.0
      end

    # Memory stats
    memory_mb = Float.round(:erlang.memory(:total) / 1_024 / 1_024, 1)
    process_count = :erlang.system_info(:process_count)

    # Provider circuit states — show tripped providers
    open_circuits =
      try do
        GiTF.Runtime.ProviderCircuit.open_providers()
      rescue
        _ -> []
      end

    socket
    |> assign(:page_title, "Health")
    |> assign(:current_path, "/health")
    |> assign(:health, health)
    |> assign(:alerts, alerts)
    |> assign(:alive, alive)
    |> assign(:ready, ready)
    |> assign(:scaling, scaling)
    |> assign(:budget_util, budget_util)
    |> assign(:memory_mb, memory_mb)
    |> assign(:process_count, process_count)
    |> assign(:open_circuits, open_circuits)
  end

  defp check_color(:ok), do: "#3fb950"
  defp check_color(:warning), do: "#d29922"
  defp check_color(:error), do: "#f85149"
  defp check_color(_), do: "#6b7280"

  defp check_icon(:ok), do: "&#10003;"
  defp check_icon(:warning), do: "&#9888;"
  defp check_icon(:error), do: "&#10007;"
  defp check_icon(_), do: "?"

  defp severity_color(:critical), do: "#f85149"
  defp severity_color(:high), do: "#f97316"
  defp severity_color(:medium), do: "#d29922"
  defp severity_color(:low), do: "#6b7280"
  defp severity_color(_), do: "#6b7280"

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <h1 class="page-title">System Health</h1>

      <%!-- Status banner --%>
      <div style={"padding:0.75rem 1rem; border-radius:6px; margin-bottom:1.5rem; border:1px solid #{if @health.status == :healthy, do: "#238636", else: "#da3633"}; background:#{if @health.status == :healthy, do: "#0d1117", else: "#1c0a0a"}"}>
        <div style="display:flex; justify-content:space-between; align-items:center">
          <div style="display:flex; align-items:center; gap:0.5rem">
            <div style={"width:12px; height:12px; border-radius:50%; background:#{if @health.status == :healthy, do: "#3fb950", else: "#f85149"}"}></div>
            <span style={"font-size:1.1rem; font-weight:600; color:#{if @health.status == :healthy, do: "#3fb950", else: "#f85149"}"}>
              {if @health.status == :healthy, do: "All Systems Operational", else: "System Degraded"}
            </span>
          </div>
          <div style="display:flex; gap:0.5rem; align-items:center">
            <span class={"badge #{if @alive, do: "badge-green", else: "badge-red"}"}>
              {if @alive, do: "alive", else: "zombie"}
            </span>
            <span class={"badge #{if @ready, do: "badge-green", else: "badge-red"}"}>
              {if @ready, do: "ready", else: "not ready"}
            </span>
          </div>
        </div>
      </div>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:1rem; margin-bottom:1.5rem">
        <%!-- Health Checks --%>
        <div class="panel">
          <div class="panel-title">Health Checks</div>
          <table class="table" style="width:100%">
            <thead><tr><th>Check</th><th style="text-align:center">Status</th></tr></thead>
            <tbody>
              <%= for {name, status} <- Enum.sort(@health.checks) do %>
                <tr>
                  <td style="color:#c9d1d9">{name |> to_string() |> String.replace("_", " ") |> String.capitalize()}</td>
                  <td style={"text-align:center; color:#{check_color(status)}"}>
                    <span style="font-size:1rem">{raw(check_icon(status))}</span>
                    <span style="font-size:0.75rem; margin-left:0.25rem">{status}</span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <div style="margin-top:0.75rem">
            <button phx-click="run_self_heal" class="btn btn-blue" style="font-size:0.8rem">Run Self-Heal</button>
          </div>
        </div>

        <%!-- Factory Scaling --%>
        <div class="panel">
          <div class="panel-title">Factory Scaling</div>
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem; margin-top:0.5rem">
            <div class="card">
              <div class="card-label">Ghost Cap</div>
              <div class="card-value blue">{@scaling.effective_max}</div>
              <div class="card-label" style="margin-top:0.25rem">of {@scaling.max_ghosts} max</div>
            </div>
            <div class="card">
              <div class="card-label">Active Ghosts</div>
              <div class="card-value green">{@scaling.active_ghosts}</div>
            </div>
            <div class="card">
              <div class="card-label">Budget Pressure</div>
              <div class={"card-value #{cond do
                @budget_util >= 85 -> "red"
                @budget_util >= 70 -> "yellow"
                true -> "green"
              end}"}>{@budget_util}%</div>
            </div>
            <div class="card">
              <div class="card-label">BEAM</div>
              <div style="color:#c9d1d9; font-size:0.85rem; margin-top:0.25rem">
                {@memory_mb} MB &middot; {@process_count} procs
              </div>
            </div>
          </div>

          <%!-- Provider circuits --%>
          <div style="margin-top:1rem; border-top:1px solid #21262d; padding-top:0.75rem">
            <div style="font-size:0.75rem; color:#6b7280; margin-bottom:0.5rem">Provider Circuits</div>
            <%= if @open_circuits == [] do %>
              <div style="color:#3fb950; font-size:0.8rem">All circuits closed</div>
            <% else %>
              <%= for provider <- @open_circuits do %>
                <div style="display:flex; justify-content:space-between; padding:0.25rem 0; font-size:0.8rem">
                  <span style="color:#c9d1d9">{provider}</span>
                  <span class="badge badge-red">open</span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Active Alerts --%>
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Active Alerts</div>
        <%= if @alerts == [] do %>
          <div class="empty" style="padding:1rem 0; color:#3fb950">No active alerts</div>
        <% else %>
          <table class="table" style="width:100%">
            <thead><tr><th>Type</th><th>Severity</th><th>Message</th></tr></thead>
            <tbody>
              <%= for {type, message} <- @alerts do %>
                <% sev = GiTF.Observability.Alerts.severity(type) %>
                <tr>
                  <td style="color:#c9d1d9; font-weight:500">{type}</td>
                  <td>
                    <span style={"color:#{severity_color(sev)}; font-weight:600; font-size:0.8rem; text-transform:uppercase"}>
                      {sev}
                    </span>
                  </td>
                  <td style="color:#8b949e; font-size:0.85rem">{message}</td>
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
