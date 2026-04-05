defmodule GiTF.Dashboard.CostsLive do
  @moduledoc """
  Cost tracking page with burn rate, mission budgets, and breakdowns.
  """

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:costs")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok, assign_data(socket)}
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

  def handle_info({:cost_recorded, _cost}, socket), do: {:noreply, assign_data(socket)}
  def handle_info({:waggle_received, _w}, socket), do: {:noreply, assign_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    summary = GiTF.Costs.summary()
    all_costs = GiTF.Archive.all(:costs)
    missions = GiTF.Missions.list()

    # Burn rate: cost in last hour
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    recent_costs =
      Enum.filter(all_costs, fn c ->
        c[:recorded_at] && DateTime.compare(c.recorded_at, one_hour_ago) != :lt
      end)

    burn_rate = Enum.sum(Enum.map(recent_costs, &(&1[:cost_usd] || 0.0)))

    # Per-mission cost breakdown
    mission_costs =
      missions
      |> Enum.filter(&(&1.status in ["active", "completed", "failed"]))
      |> Enum.map(fn m ->
        costs = GiTF.Costs.for_quest(m.id)
        spent = GiTF.Costs.total(costs)
        budget = GiTF.Budget.budget_for(m.id)
        remaining = GiTF.Budget.remaining(m.id)
        pct = if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0

        %{
          id: m.id,
          name: m.name,
          status: m.status,
          spent: spent,
          budget: budget,
          remaining: remaining,
          pct: pct,
          op_count: length(m[:ops] || [])
        }
      end)
      |> Enum.sort_by(& &1.spent, :desc)

    # Hourly cost trend (last 12 hours)
    hourly_trend = build_hourly_trend(all_costs, 12)

    socket
    |> assign(:page_title, "Costs")
    |> assign(:current_path, "/costs")
    |> assign(:summary, summary)
    |> assign(:burn_rate, burn_rate)
    |> assign(:mission_costs, mission_costs)
    |> assign(:hourly_trend, hourly_trend)
    |> assign(:total_records, length(all_costs))
  end

  defp build_hourly_trend(costs, hours) do
    now = DateTime.utc_now()

    0..(hours - 1)
    |> Enum.map(fn offset ->
      hour_start = DateTime.add(now, -(offset + 1) * 3600, :second)
      hour_end = DateTime.add(now, -offset * 3600, :second)

      hour_costs =
        Enum.filter(costs, fn c ->
          c[:recorded_at] &&
            DateTime.compare(c.recorded_at, hour_start) != :lt &&
            DateTime.compare(c.recorded_at, hour_end) == :lt
        end)

      cost = Enum.sum(Enum.map(hour_costs, &(&1[:cost_usd] || 0.0)))

      tokens =
        Enum.sum(Enum.map(hour_costs, &((&1[:input_tokens] || 0) + (&1[:output_tokens] || 0))))

      label = if offset == 0, do: "now", else: "#{offset}h ago"

      %{label: label, cost: cost, tokens: tokens}
    end)
    |> Enum.reverse()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Cost Tracking</h1>
        <button phx-click="refresh" class="btn btn-grey" style="font-size:0.8rem">Refresh</button>
      </div>

      <!-- Summary cards -->
      <div class="cards">
        <div class="card">
          <div class="card-label">Total Spend</div>
          <div class="card-value green">{format_cost(@summary.total_cost)}</div>
          <div class="card-label" style="margin-top:0.25rem">{@total_records} records</div>
        </div>
        <div class="card">
          <div class="card-label">Burn Rate</div>
          <div class={"card-value #{if @burn_rate > 1.0, do: "red", else: "yellow"}"}>
            {format_cost(@burn_rate)}
          </div>
          <div class="card-label" style="margin-top:0.25rem">per hour</div>
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

      <!-- Hourly trend -->
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Cost Trend (Last 12 Hours)</div>
        <% max_cost = Enum.max_by(@hourly_trend, & &1.cost, fn -> %{cost: 0} end).cost %>
        <div style="display:flex; align-items:flex-end; gap:2px; height:80px; padding:0.5rem 0">
          <%= for bucket <- @hourly_trend do %>
            <div style="flex:1; display:flex; flex-direction:column; align-items:center; height:100%">
              <div style="flex:1; width:100%; display:flex; align-items:flex-end">
                <div style={"width:100%; background:#1f6feb; border-radius:2px 2px 0 0; min-height:#{if bucket.cost > 0, do: "2px", else: "0"}; height:#{bar_height(bucket.cost, max_cost)}%"} title={"#{format_cost(bucket.cost)} | #{format_tokens(bucket.tokens)} tokens"}></div>
              </div>
              <div style="font-size:0.55rem; color:#6e7681; margin-top:2px; white-space:nowrap">{bucket.label}</div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Mission budgets -->
      <%= if @mission_costs != [] do %>
        <div class="panel" style="margin-bottom:1.5rem">
          <div class="panel-title">Mission Budgets</div>
          <table>
            <thead>
              <tr>
                <th>Mission</th>
                <th style="text-align:right">Spent</th>
                <th style="text-align:right">Budget</th>
                <th style="text-align:right">Remaining</th>
                <th style="width:120px">Usage</th>
              </tr>
            </thead>
            <tbody>
              <%= for m <- @mission_costs do %>
                <tr>
                  <td>
                    <a href={"/dashboard/missions/#{m.id}"} style="color:#58a6ff">{m.name || short_id(m.id)}</a>
                    <span class={"badge #{status_badge(m.status)}"} style="margin-left:0.35rem">{m.status}</span>
                  </td>
                  <td style="text-align:right; font-family:monospace">{format_cost(m.spent)}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(m.budget)}</td>
                  <td style={"text-align:right; font-family:monospace; color:#{if m.remaining < 0, do: "#f85149", else: "#c9d1d9"}"}>
                    {format_cost(m.remaining)}
                  </td>
                  <td>
                    <div class="cost-bar">
                      <div class={"cost-bar-fill"} style={"width:#{min(m.pct, 100)}%; background:#{budget_color(m.pct)}"}></div>
                    </div>
                    <div style="font-size:0.65rem; color:#8b949e; text-align:center">{m.pct}%</div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <!-- By model -->
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">By Model</div>
        <%= if @summary.by_model == %{} do %>
          <div class="empty">No cost data recorded yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Model</th>
                <th style="text-align:right">Cost</th>
                <th style="text-align:right">Input</th>
                <th style="text-align:right">Output</th>
                <th style="width:120px">Share</th>
              </tr>
            </thead>
            <tbody>
              <%= for {model, data} <- Enum.sort_by(@summary.by_model, fn {_, d} -> d.cost end, :desc) do %>
                <tr>
                  <td style="font-size:0.85rem">{model}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_tokens(data.output_tokens)}</td>
                  <td>
                    <div class="cost-bar">
                      <div class="cost-bar-fill" style={"width:#{cost_pct(@summary.total_cost, data.cost)}%"}></div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>

      <!-- By category -->
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
                <th style="text-align:right">Input</th>
                <th style="text-align:right">Output</th>
                <th style="width:120px">Share</th>
              </tr>
            </thead>
            <tbody>
              <%= for {cat, data} <- Enum.sort_by(@summary.by_category, fn {_, d} -> d.cost end, :desc) do %>
                <tr>
                  <td>{cat}</td>
                  <td style="text-align:right; font-family:monospace">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_tokens(data.output_tokens)}</td>
                  <td>
                    <div class="cost-bar">
                      <div class="cost-bar-fill" style={"width:#{cost_pct(@summary.total_cost, data.cost)}%"}></div>
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

  # -- Helpers ---------------------------------------------------------------

  defp cost_pct(total, _part) when total == 0 or total == 0.0, do: 0.0
  defp cost_pct(total, part), do: Float.round(part / total * 100.0, 1)

  defp bar_height(_cost, max) when max == 0 or max == 0.0, do: 0
  defp bar_height(cost, max), do: round(cost / max * 100)

  defp budget_color(pct) when pct > 90, do: "#f85149"
  defp budget_color(pct) when pct > 70, do: "#d29922"
  defp budget_color(_), do: "#1f6feb"
end
