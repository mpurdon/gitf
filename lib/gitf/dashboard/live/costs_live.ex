defmodule GiTF.Dashboard.CostsLive do
  @moduledoc """
  Cost tracking page.

  Displays aggregate cost statistics -- total spend, token counts,
  breakdowns by model and by ghost. Uses `GiTF.Costs.summary/0` as its
  sole data source, keeping the LiveView thin and the data
  transformation in the context module where it belongs.
  """

  use Phoenix.LiveView

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:costs")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    summary = GiTF.Costs.summary()

    {:ok,
     socket
     |> assign(:page_title, "Costs")
     |> assign(:current_path, "/costs")
     |> assign(:summary, summary)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :summary, GiTF.Costs.summary())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, :summary, GiTF.Costs.summary())}
  end

  def handle_info({:cost_recorded, _cost}, socket) do
    {:noreply, assign(socket, :summary, GiTF.Costs.summary())}
  end

  def handle_info({:waggle_received, _waggle}, socket) do
    {:noreply, assign(socket, :summary, GiTF.Costs.summary())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Cost Tracking</h1>
        <button phx-click="refresh" style="background:#1f6feb33; color:#58a6ff; border:1px solid #1f6feb55; padding:0.4rem 1rem; border-radius:6px; cursor:pointer; font-size:0.85rem">
          Refresh
        </button>
      </div>

      <div class="cards">
        <div class="card">
          <div class="card-label">Total Cost</div>
          <div class="card-value green">{format_cost(@summary.total_cost)}</div>
        </div>
        <div class="card">
          <div class="card-label">Input Tokens</div>
          <div class="card-value">{format_tokens(@summary.total_input_tokens)}</div>
        </div>
        <div class="card">
          <div class="card-label">Output Tokens</div>
          <div class="card-value">{format_tokens(@summary.total_output_tokens)}</div>
        </div>
      </div>

      <div class="panel">
        <div class="panel-title">By Model</div>
        <%= if @summary.by_model == %{} do %>
          <div class="empty">No cost data recorded yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Model</th>
                <th style="text-align:right">Cost</th>
                <th style="text-align:right">Input Tokens</th>
                <th style="text-align:right">Output Tokens</th>
              </tr>
            </thead>
            <tbody>
              <%= for {model, data} <- @summary.by_model do %>
                <tr>
                  <td>{model}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.output_tokens)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>

      <div class="panel">
        <div class="panel-title">By Category</div>
        <%= if @summary.by_category == %{} do %>
          <div class="empty">No cost data recorded yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Category</th>
                <th style="text-align:right">Cost</th>
                <th style="text-align:right">Input Tokens</th>
                <th style="text-align:right">Output Tokens</th>
                <th style="width:120px">Share</th>
              </tr>
            </thead>
            <tbody>
              <%= for {category, data} <- @summary.by_category do %>
                <tr>
                  <td>{category}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.output_tokens)}</td>
                  <td>
                    <div class="cost-bar">
                      <div class="cost-bar-fill" style={"width: #{cost_percentage(@summary.total_cost, data.cost)}%"}></div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>

      <div class="panel">
        <div class="panel-title">By Bee</div>
        <%= if @summary.by_bee == %{} do %>
          <div class="empty">No cost data recorded yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Bee ID</th>
                <th style="text-align:right">Cost</th>
                <th style="text-align:right">Input Tokens</th>
                <th style="text-align:right">Output Tokens</th>
                <th style="width:120px">Share</th>
              </tr>
            </thead>
            <tbody>
              <%= for {ghost_id, data} <- @summary.by_bee do %>
                <tr>
                  <td style="font-family:monospace; font-size:0.8rem">{ghost_id}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace">{format_tokens(data.output_tokens)}</td>
                  <td>
                    <div class="cost-bar">
                      <div class="cost-bar-fill" style={"width: #{cost_percentage(@summary.total_cost, data.cost)}%"}></div>
                    </div>
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

  defp format_cost(cost) when is_float(cost), do: "$#{:erlang.float_to_binary(cost, decimals: 4)}"

  defp format_cost(cost) when is_integer(cost),
    do: "$#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"

  defp format_cost(_), do: "$0.0000"

  defp format_tokens(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M"
  defp format_tokens(count) when count >= 1_000, do: "#{Float.round(count / 1_000, 1)}K"
  defp format_tokens(count), do: "#{count}"

  defp cost_percentage(total, _part) when total == 0 or total == 0.0, do: 0.0
  defp cost_percentage(total, part), do: Float.round(part / total * 100.0, 1)
end
