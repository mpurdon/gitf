defmodule GiTF.Dashboard.ModelPerformanceLive do
  @moduledoc """
  Model performance dashboard — shows cost-effectiveness, phase comparison,
  and per-model metrics to inform model tier decisions.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:costs")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok, socket |> init_toasts() |> assign_data()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info({:cost_recorded, _}, socket), do: {:noreply, assign_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    models = GiTF.ModelPerformance.summary()
    phase_comparison = GiTF.ModelPerformance.phase_comparison()

    socket
    |> assign(:page_title, "Model Performance")
    |> assign(:current_path, "/models")
    |> assign(:models, models)
    |> assign(:phase_comparison, phase_comparison)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Model Performance</h1>
        <button phx-click="refresh" class="btn btn-grey" style="font-size:0.8rem">Refresh</button>
      </div>

      <%!-- Model Leaderboard --%>
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Model Leaderboard</div>
        <%= if @models == [] do %>
          <div class="empty">No model data recorded yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Model</th>
                <th style="text-align:right">Ops</th>
                <th style="text-align:right">Success</th>
                <th style="text-align:right">Avg Quality</th>
                <th style="text-align:right">Retry Rate</th>
                <th style="text-align:right">Total Cost</th>
                <th style="text-align:right">Cost/Success</th>
              </tr>
            </thead>
            <tbody>
              <%= for m <- @models do %>
                <tr>
                  <td style="font-size:0.85rem">{m.model}</td>
                  <td style="text-align:right">{m.total_ops}</td>
                  <td style="text-align:right">
                    <div style="display:flex; align-items:center; justify-content:flex-end; gap:0.35rem">
                      <div style="width:40px; height:4px; background:#21262d; border-radius:2px; overflow:hidden">
                        <div style={"height:100%; border-radius:2px; background:#{rate_color(m.success_rate)}; width:#{Float.round((m.success_rate || 0) * 100, 0)}%"}></div>
                      </div>
                      <span style={"color:#{rate_color(m.success_rate)}; min-width:36px"}>{format_pct(m.success_rate)}</span>
                    </div>
                  </td>
                  <td style="text-align:right">{if m.avg_quality, do: "#{m.avg_quality}", else: "-"}</td>
                  <td style={"text-align:right; color:#{retry_color(m.retry_rate)}"}>{format_pct(m.retry_rate)}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(m.total_cost)}</td>
                  <td style="text-align:right; font-family:monospace">
                    {if m.cost_per_success, do: format_cost(m.cost_per_success), else: "-"}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>

      <%!-- Phase Comparison --%>
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Phase Comparison</div>
        <%= if @phase_comparison == %{} do %>
          <div class="empty">No phase data recorded yet.</div>
        <% else %>
          <%= for {phase, models} <- Enum.sort_by(@phase_comparison, fn {p, _} -> phase_order(p) end) do %>
            <div style="margin-bottom:1rem">
              <div style="font-weight:600; margin-bottom:0.35rem; color:#c9d1d9">{phase}</div>
              <table style="margin-bottom:0">
                <thead>
                  <tr>
                    <th>Model</th>
                    <th style="text-align:right">Ops</th>
                    <th style="text-align:right">Success</th>
                    <th style="text-align:right">Quality</th>
                    <th style="text-align:right">Cost</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for m <- models do %>
                    <tr>
                      <td style="font-size:0.85rem">{m.model}</td>
                      <td style="text-align:right">{m.ops}</td>
                      <td style={"text-align:right; color:#{rate_color(m.success_rate)}"}>{format_pct(m.success_rate)}</td>
                      <td style="text-align:right">{if m.avg_quality, do: "#{m.avg_quality}", else: "-"}</td>
                      <td style="text-align:right; font-family:monospace">{format_cost(m.cost)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- Cost Efficiency --%>
      <div class="panel">
        <div class="panel-title">Cost per Successful Op</div>
        <%= if @models == [] do %>
          <div class="empty">No model data recorded yet.</div>
        <% else %>
          <% ranked = @models |> Enum.filter(& &1.cost_per_success) |> Enum.sort_by(& &1.cost_per_success) %>
          <% max_cps = case ranked do [h | _] -> h.cost_per_success; _ -> 1 end %>
          <%= for m <- ranked do %>
            <div style="display:flex; align-items:center; gap:0.75rem; margin-bottom:0.5rem">
              <div style="width:180px; font-size:0.85rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis">{m.model}</div>
              <div style="flex:1">
                <div class="cost-bar">
                  <div class="cost-bar-fill" style={"width:#{bar_pct(m.cost_per_success, Enum.max([max_cps * 1.2, 0.01]))}%; background:#{efficiency_color(m, ranked)}"}></div>
                </div>
              </div>
              <div style="width:70px; text-align:right; font-family:monospace; font-size:0.85rem">{format_cost(m.cost_per_success)}</div>
            </div>
          <% end %>
        <% end %>
      </div>
    </.live_component>
    """
  end

  # -- Helpers ---------------------------------------------------------------

  defp format_pct(rate) when is_float(rate), do: "#{Float.round(rate * 100, 1)}%"
  defp format_pct(_), do: "-"

  defp rate_color(rate) when is_float(rate) and rate >= 0.9, do: "#3fb950"
  defp rate_color(rate) when is_float(rate) and rate >= 0.7, do: "#d29922"
  defp rate_color(rate) when is_float(rate), do: "#f85149"
  defp rate_color(_), do: "#8b949e"

  defp retry_color(rate) when is_float(rate) and rate > 0.3, do: "#f85149"
  defp retry_color(rate) when is_float(rate) and rate > 0.1, do: "#d29922"
  defp retry_color(_), do: "#8b949e"

  defp bar_pct(_, max) when max == 0 or max == 0.0, do: 0
  defp bar_pct(val, max), do: Float.round(val / max * 100, 1)

  defp efficiency_color(model, [best | _]) when model.model == best.model, do: "#3fb950"
  defp efficiency_color(_, _), do: "#1f6feb"

  @phase_order ~w(research requirements design review planning implementation validation simplify scoring)
  defp phase_order(phase) do
    Enum.find_index(@phase_order, &(&1 == phase)) || 99
  end
end
