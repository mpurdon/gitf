defmodule GiTF.Dashboard.CostsLive do
  @moduledoc """
  Cost tracking page with burn rate gauges, mission budgets, and breakdowns.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(20)

  @range_options [
    {"1h", 1},
    {"4h", 4},
    {"8h", 8},
    {"24h", 24},
    {"7d", 168},
    {"30d", 720},
    {"All", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:costs")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    {:ok,
     socket
     |> assign(:cost_sort, :spent)
     |> assign(:trend_range, "24h")
     |> init_toasts()
     |> assign_data()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_event("sort_costs", %{"col" => col}, socket) do
    {:noreply, socket |> assign(:cost_sort, String.to_existing_atom(col)) |> assign_data()}
  end

  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:trend_range, range) |> assign_data()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info({:cost_recorded, _cost}, socket), do: {:noreply, assign_data(socket)}

  def handle_info({:waggle_received, waggle}, socket),
    do: {:noreply, socket |> maybe_apply_toast(waggle) |> assign_data()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    summary = GiTF.Costs.summary()
    all_costs = GiTF.Archive.all(:costs)
    missions = GiTF.Missions.list()

    # Burn rate: cost in last hour
    one_hour_ago = DateTime.shift(DateTime.utc_now(), hour: -1)

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
      |> Enum.sort_by(&Map.get(&1, socket.assigns[:cost_sort] || :spent, 0), :desc)

    # Trend based on selected range
    range = socket.assigns[:trend_range] || "24h"
    {hours, buckets} = range_config(range)
    trend = build_trend(all_costs, hours, buckets)

    # Cache stats
    total_input = summary.total_input_tokens
    total_output = summary.total_output_tokens
    cache_read = summary[:total_cache_read_tokens] || 0
    cache_write = summary[:total_cache_write_tokens] || 0
    total_all = total_input + total_output + cache_read + cache_write
    cache_hit_pct = if total_all > 0, do: Float.round(cache_read / total_all * 100, 1), else: 0.0

    # Budget usage across all missions
    total_budget = Enum.sum(Enum.map(mission_costs, & &1.budget))
    total_spent = Enum.sum(Enum.map(mission_costs, & &1.spent))
    budget_pct = if total_budget > 0, do: Float.round(total_spent / total_budget * 100, 1), else: 0.0

    socket
    |> assign(:page_title, "Costs")
    |> assign(:current_path, "/costs")
    |> assign(:summary, summary)
    |> assign(:burn_rate, burn_rate)
    |> assign(:mission_costs, mission_costs)
    |> assign(:trend, trend)
    |> assign(:total_records, length(all_costs))
    |> assign(:cache_hit_pct, cache_hit_pct)
    |> assign(:budget_pct, budget_pct)
    |> assign(:total_budget, total_budget)
    |> assign(:total_spent, total_spent)
    |> assign(:range_options, @range_options)
  end

  defp range_config("1h"), do: {1, 12}
  defp range_config("4h"), do: {4, 16}
  defp range_config("8h"), do: {8, 16}
  defp range_config("24h"), do: {24, 24}
  defp range_config("7d"), do: {168, 28}
  defp range_config("30d"), do: {720, 30}
  defp range_config("All"), do: {nil, 24}
  defp range_config(_), do: {24, 24}

  defp build_trend(costs, nil, buckets) do
    # "All" time — find the earliest cost and span to now
    earliest =
      costs
      |> Enum.map(& &1[:recorded_at])
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> DateTime.utc_now() end)

    total_hours = max(DateTime.diff(DateTime.utc_now(), earliest, :hour), 1)
    build_trend(costs, total_hours, buckets)
  end

  defp build_trend(costs, hours, buckets) do
    now = DateTime.utc_now()
    bucket_hours = max(div(hours, buckets), 1)

    0..(buckets - 1)
    |> Enum.map(fn i ->
      bucket_end = DateTime.shift(now, hour: -(i * bucket_hours))
      bucket_start = DateTime.shift(now, hour: -((i + 1) * bucket_hours))

      bucket_costs =
        Enum.filter(costs, fn c ->
          c[:recorded_at] &&
            DateTime.compare(c.recorded_at, bucket_start) != :lt &&
            DateTime.compare(c.recorded_at, bucket_end) == :lt
        end)

      cost = Enum.sum(Enum.map(bucket_costs, &(&1[:cost_usd] || 0.0)))
      tokens = Enum.sum(Enum.map(bucket_costs, &((&1[:input_tokens] || 0) + (&1[:output_tokens] || 0))))

      label = cond do
        i == 0 -> "now"
        bucket_hours >= 24 -> "#{div(i * bucket_hours, 24)}d"
        true -> "#{i * bucket_hours}h"
      end

      %{label: label, cost: cost, tokens: tokens}
    end)
    |> Enum.reverse()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">Cost Tracking</h1>
        <button phx-click="refresh" class="btn btn-grey" style="font-size:0.8rem">Refresh</button>
      </div>

      <%!-- Row 1: Gauges + Key Metrics --%>
      <div style="display:grid; grid-template-columns: repeat(3, 1fr); gap:0.75rem; margin-bottom:0.75rem">
        <%!-- Total Spend Gauge --%>
        <div class="card" style="display:flex; align-items:center; gap:1rem; padding:1rem">
          <div>
            {gauge_svg(@budget_pct, budget_gauge_color(@budget_pct))}
          </div>
          <div>
            <div class="card-label">Total Spend</div>
            <div class="card-value green" style="font-size:1.4rem">{format_cost(@total_spent, 2)}</div>
            <div style="font-size:0.7rem; color:#8b949e">of {format_cost(@total_budget, 2)} budget</div>
          </div>
        </div>

        <%!-- Burn Rate Gauge --%>
        <div class="card" style="display:flex; align-items:center; gap:1rem; padding:1rem">
          <div>
            <% burn_pct = min(@burn_rate / max(1.0, @total_budget / 24) * 100, 100) %>
            {gauge_svg(burn_pct, burn_color(@burn_rate))}
          </div>
          <div>
            <div class="card-label">Burn Rate</div>
            <div class={"card-value #{if @burn_rate > 1.0, do: "red", else: "yellow"}"} style="font-size:1.4rem">
              {format_cost(@burn_rate, 2)}
            </div>
            <div style="font-size:0.7rem; color:#8b949e">per hour | {@total_records} records</div>
          </div>
        </div>

        <%!-- Cache Hit Gauge --%>
        <div class="card" style="display:flex; align-items:center; gap:1rem; padding:1rem">
          <div>
            {gauge_svg(@cache_hit_pct, cache_color(@cache_hit_pct))}
          </div>
          <div>
            <div class="card-label">Cache Hit Rate</div>
            <div class="card-value" style="font-size:1.4rem; color:#a78bfa">{@cache_hit_pct}%</div>
            <div style="font-size:0.7rem; color:#8b949e">{format_tokens(@summary[:total_cache_read_tokens] || 0)} read</div>
          </div>
        </div>
      </div>

      <%!-- Row 2: Token breakdown (compact) --%>
      <div style="display:grid; grid-template-columns: repeat(4, 1fr); gap:0.75rem; margin-bottom:0.75rem">
        <div class="card" style="padding:0.75rem">
          <div class="card-label">Input Tokens</div>
          <div class="card-value" style="font-size:1.2rem">{format_tokens(@summary.total_input_tokens)}</div>
        </div>
        <div class="card" style="padding:0.75rem">
          <div class="card-label">Output Tokens</div>
          <div class="card-value" style="font-size:1.2rem">{format_tokens(@summary.total_output_tokens)}</div>
        </div>
        <div class="card" style="padding:0.75rem">
          <div class="card-label">Cache Read</div>
          <div class="card-value" style="font-size:1.2rem; color:#a78bfa">{format_tokens(@summary[:total_cache_read_tokens] || 0)}</div>
        </div>
        <div class="card" style="padding:0.75rem">
          <div class="card-label">Cache Write</div>
          <div class="card-value" style="font-size:1.2rem; color:#8b5cf6">{format_tokens(@summary[:total_cache_write_tokens] || 0)}</div>
        </div>
      </div>

      <%!-- Cost Trend with range selector --%>
      <div class="panel" style="margin-bottom:0.75rem">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.75rem; padding-bottom:0.5rem; border-bottom:1px solid #30363d">
          <span style="font-size:1rem; font-weight:600; color:#f0f6fc">Cost Trend</span>
          <div style="display:flex; gap:2px">
            <%= for {label, _hours} <- @range_options do %>
              <button
                phx-click="set_range"
                phx-value-range={label}
                style={"padding:0.2rem 0.5rem; font-size:0.65rem; border-radius:4px; border:1px solid #{if @trend_range == label, do: "#58a6ff", else: "#30363d"}; background:#{if @trend_range == label, do: "#1f6feb33", else: "transparent"}; color:#{if @trend_range == label, do: "#58a6ff", else: "#8b949e"}; cursor:pointer"}
              >
                {label}
              </button>
            <% end %>
          </div>
        </div>
        <% max_cost = Enum.max_by(@trend, & &1.cost, fn -> %{cost: 0} end).cost %>
        <div style="display:flex; align-items:flex-end; gap:2px; height:90px; padding:0.25rem 0">
          <%= for bucket <- @trend do %>
            <div style="flex:1; display:flex; flex-direction:column; align-items:center; height:100%">
              <div style="flex:1; width:100%; display:flex; align-items:flex-end">
                <div style={"width:100%; background:#1f6feb; border-radius:2px 2px 0 0; min-height:#{if bucket.cost > 0, do: "2px", else: "0"}; height:#{bar_height(bucket.cost, max_cost)}%"} title={"#{format_cost(bucket.cost)} | #{format_tokens(bucket.tokens)} tokens"}></div>
              </div>
              <div style="font-size:0.5rem; color:#6e7681; margin-top:2px; white-space:nowrap">{bucket.label}</div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Two-column: Mission Budgets + By Model --%>
      <div style="display:grid; grid-template-columns: 1fr 1fr; gap:0.75rem; margin-bottom:0.75rem">
        <%!-- Mission Budgets --%>
        <div class="panel" style="margin-bottom:0">
          <div class="panel-title" style="margin-bottom:0.5rem">Mission Budgets</div>
          <%= if @mission_costs != [] do %>
            <table>
              <thead>
                <tr>
                  <th>Mission</th>
                  <th class="sortable" phx-click="sort_costs" phx-value-col="spent" style="text-align:right">Spent {if @cost_sort == :spent, do: "▼"}</th>
                  <th class="sortable" phx-click="sort_costs" phx-value-col="pct" style="text-align:right; width:100px">Usage {if @cost_sort == :pct, do: "▼"}</th>
                </tr>
              </thead>
              <tbody>
                <%= for m <- @mission_costs do %>
                  <tr>
                    <td style="font-size:0.8rem">
                      <a href={"/dashboard/missions/#{m.id}"} style="color:#58a6ff">{m.name || short_id(m.id)}</a>
                      <span class={"badge #{status_badge(m.status)}"} style="margin-left:0.25rem; font-size:0.6rem">{m.status}</span>
                    </td>
                    <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_cost(m.spent)}</td>
                    <td>
                      <div style="display:flex; align-items:center; gap:0.2rem">
                        <div class="cost-bar" style="flex:1">
                          <div class="cost-bar-fill" style={"width:#{min(m.pct, 100)}%; background:#{budget_color(m.pct)}"}></div>
                        </div>
                        <span style="font-size:0.6rem; color:#8b949e; min-width:28px; text-align:right">{m.pct}%</span>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% else %>
            <div class="empty">No missions yet.</div>
          <% end %>
        </div>

        <%!-- By Model --%>
        <div class="panel" style="margin-bottom:0">
          <div class="panel-title" style="margin-bottom:0.5rem">By Model</div>
          <%= if @summary.by_model == %{} do %>
            <div class="empty">No cost data recorded yet.</div>
          <% else %>
            <table>
              <thead>
                <tr>
                  <th>Model</th>
                  <th style="text-align:right">Cost</th>
                  <th style="width:100px">Share</th>
                </tr>
              </thead>
              <tbody>
                <%= for {model, data} <- Enum.sort_by(@summary.by_model, fn {_, d} -> d.cost end, :desc) do %>
                  <tr>
                    <td style="font-size:0.8rem">{model}</td>
                    <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_cost(data.cost)}</td>
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
      </div>

      <%!-- Two-column: Productive vs Overhead + By Phase --%>
      <div style="display:grid; grid-template-columns: 1fr 1fr; gap:0.75rem; margin-bottom:0.75rem">
        <%!-- Productive vs Overhead --%>
        <div class="panel" style="margin-bottom:0">
          <div class="panel-title" style="margin-bottom:0.5rem">Productive vs Overhead</div>
          <%= if @summary.by_phase_type == %{} do %>
            <div class="empty">No cost data recorded yet.</div>
          <% else %>
            <div style="display:flex; gap:0.75rem; margin-bottom:0.75rem">
              <%= for type <- ["productive", "overhead"] do %>
                <%= if data = @summary.by_phase_type[type] do %>
                  <% pct = cost_pct(@summary.total_cost, data.cost) %>
                  <div style="flex:1; text-align:center">
                    {gauge_svg(pct, phase_type_color(type))}
                    <div style={"font-size:0.8rem; font-weight:600; color:#{phase_type_color(type)}; margin-top:0.25rem"}>{String.capitalize(type)}</div>
                    <div style="font-size:0.75rem; color:#8b949e">{format_cost(data.cost)}</div>
                  </div>
                <% end %>
              <% end %>
            </div>
            <%= if unknown = @summary.by_phase_type["unknown"] do %>
              <div style="font-size:0.75rem; color:#8b949e; text-align:center">Unknown: {format_cost(unknown.cost)}</div>
            <% end %>
          <% end %>
        </div>

        <%!-- By Phase --%>
        <div class="panel" style="margin-bottom:0">
          <div class="panel-title" style="margin-bottom:0.5rem">By Phase</div>
          <%= if @summary.by_phase == %{} do %>
            <div class="empty">No cost data recorded yet.</div>
          <% else %>
            <table>
              <thead>
                <tr>
                  <th>Phase</th>
                  <th style="text-align:right">Cost</th>
                  <th style="width:100px">Share</th>
                </tr>
              </thead>
              <tbody>
                <%= for {phase, data} <- Enum.sort_by(@summary.by_phase, fn {_, d} -> d.cost end, :desc) do %>
                  <tr>
                    <td>
                      <span style={"color:#{phase_type_color(phase_to_type(phase))}; font-size:0.8rem"}>{phase}</span>
                    </td>
                    <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_cost(data.cost)}</td>
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
      </div>

      <%!-- By Category (full width, compact) --%>
      <%= if @summary.by_category != %{} do %>
        <div class="panel" style="margin-bottom:0.75rem">
          <div class="panel-title" style="margin-bottom:0.5rem">By Category</div>
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
                  <td style="font-size:0.85rem">{cat}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.8rem">{format_cost(data.cost)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.75rem; color:#8b949e">{format_tokens(data.input_tokens)}</td>
                  <td style="text-align:right; font-family:monospace; font-size:0.75rem; color:#8b949e">{format_tokens(data.output_tokens)}</td>
                  <td>
                    <div class="cost-bar">
                      <div class="cost-bar-fill" style={"width:#{cost_pct(@summary.total_cost, data.cost)}%"}></div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.live_component>
    """
  end

  # -- SVG Gauge ---------------------------------------------------------------

  defp gauge_svg(pct, color) do
    # Semi-circle arc gauge (0-100%)
    pct = min(max(pct, 0), 100)
    arc_pct = pct / 100.0

    angle = :math.pi * (1.0 - arc_pct)
    ex = 60 + 45 * :math.cos(angle)
    ey = 60 - 45 * :math.sin(angle)
    large = if arc_pct > 0.5, do: "1", else: "0"

    assigns = %{pct: pct, color: color, ex: Float.round(ex, 1), ey: Float.round(ey, 1), large: large, arc_pct: arc_pct}

    Phoenix.LiveView.TagEngine.component(
      &gauge_component/1,
      assigns,
      {__ENV__.module, __ENV__.function, __ENV__.file, __ENV__.line}
    )
  end

  defp gauge_component(assigns) do
    ~H"""
    <svg viewBox="0 0 120 70" width="90" height="55">
      <path d="M 15 60 A 45 45 0 0 1 105 60" fill="none" stroke="#21262d" stroke-width="8" stroke-linecap="round" />
      <%= if @arc_pct > 0.01 do %>
        <path
          d={"M 15 60 A 45 45 0 #{@large} 1 #{@ex} #{@ey}"}
          fill="none"
          stroke={@color}
          stroke-width="8"
          stroke-linecap="round"
        />
      <% end %>
      <text x="60" y="56" text-anchor="middle" fill={@color} font-size="15" font-weight="bold">
        {round(@pct)}%
      </text>
    </svg>
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

  defp budget_gauge_color(pct) when pct > 90, do: "#f85149"
  defp budget_gauge_color(pct) when pct > 70, do: "#d29922"
  defp budget_gauge_color(pct) when pct > 40, do: "#58a6ff"
  defp budget_gauge_color(_), do: "#3fb950"

  defp burn_color(rate) when rate > 2.0, do: "#f85149"
  defp burn_color(rate) when rate > 1.0, do: "#d29922"
  defp burn_color(_), do: "#3fb950"

  defp cache_color(pct) when pct > 50, do: "#3fb950"
  defp cache_color(pct) when pct > 20, do: "#a78bfa"
  defp cache_color(_), do: "#d29922"

  defp phase_type_color("productive"), do: "#3fb950"
  defp phase_type_color("overhead"), do: "#d29922"
  defp phase_type_color(_), do: "#8b949e"

  @overhead_phases ~w(review validation simplify scoring orchestration)
  defp phase_to_type(phase) when phase in @overhead_phases, do: "overhead"
  defp phase_to_type(_), do: "productive"
end
