defmodule GiTF.Dashboard.CostsLive do
  @moduledoc """
  Cost tracking page with burn rate gauges, mission budgets, and breakdowns.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(20)

  @range_options ~w(1h 4h 8h Today 7d 30d All)

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
     |> assign(:trend_range, "Today")
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
    valid = @range_options
    range = if range in valid, do: range, else: "Today"
    socket = socket |> assign(:trend_range, range) |> assign_data()
    {:noreply, push_event(socket, "store_session", %{key: "costs_range", value: range})}
  end

  def handle_event("restore_session", %{"key" => "costs_range", "value" => range}, socket) do
    valid = @range_options
    range = if range in valid, do: range, else: "Today"
    {:noreply, socket |> assign(:trend_range, range) |> assign_data()}
  end

  def handle_event("restore_session", _params, socket), do: {:noreply, socket}

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
    all_costs_raw = GiTF.Archive.all(:costs)
    missions = GiTF.Missions.list()

    # Page-level date range filter — applies to ALL data on the page
    range = socket.assigns[:trend_range] || "24h"
    {hours, buckets} = range_config(range)
    all_costs = filter_costs_by_range(all_costs_raw, hours)

    # Compute summary from filtered costs
    summary = compute_summary(all_costs)

    # Burn rate: total filtered spend / active factory hours (not wall-clock)
    total_filtered_cost = all_costs |> Enum.map(&(&1[:cost_usd] || 0.0)) |> Enum.sum() |> to_float()
    active_hours = compute_active_hours(missions, hours)
    burn_rate = if active_hours > 0, do: Float.round(total_filtered_cost / active_hours, 4), else: 0.0

    # Per-mission cost breakdown — group filtered costs by mission_id
    costs_by_mission = Enum.group_by(all_costs, & &1[:mission_id])

    mission_costs =
      missions
      |> Enum.filter(&(&1.status in ["active", "completed", "failed"]))
      |> Enum.map(fn m ->
        mission_costs_list = costs_by_mission[m.id] || []
        spent = mission_costs_list |> Enum.map(&(&1[:cost_usd] || 0.0)) |> Enum.sum() |> to_float() |> Float.round(6)
        budget = GiTF.Budget.budget_for(m.id)
        remaining = Float.round(to_float(budget) - spent, 6)
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
      |> Enum.filter(&(&1.spent > 0))
      |> Enum.sort_by(&Map.get(&1, socket.assigns[:cost_sort] || :spent, 0), :desc)

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

    # Productive vs overhead vs rework percentages for stacked bar
    prod_data = summary.by_phase_type["productive"]
    overhead_data = summary.by_phase_type["overhead"]
    rework_data = summary.by_phase_type["rework"]
    prod_pct = if prod_data, do: cost_pct(summary.total_cost, prod_data.cost), else: 0.0
    overhead_pct = if overhead_data, do: cost_pct(summary.total_cost, overhead_data.cost), else: 0.0
    rework_pct = if rework_data, do: cost_pct(summary.total_cost, rework_data.cost), else: 0.0

    socket
    |> assign(:page_title, "Costs")
    |> assign(:current_path, "/costs")
    |> assign(:summary, summary)
    |> assign(:burn_rate, burn_rate)
    |> assign(:active_hours, active_hours)
    |> assign(:mission_costs, mission_costs)
    |> assign(:trend, trend)
    |> assign(:total_records, length(all_costs))
    |> assign(:cache_hit_pct, cache_hit_pct)
    |> assign(:budget_pct, budget_pct)
    |> assign(:total_budget, total_budget)
    |> assign(:total_spent, total_spent)
    |> assign(:range_options, @range_options)
    |> assign(:prod_pct, prod_pct)
    |> assign(:overhead_pct, overhead_pct)
    |> assign(:prod_cost, if(prod_data, do: prod_data.cost, else: 0.0))
    |> assign(:overhead_cost, if(overhead_data, do: overhead_data.cost, else: 0.0))
    |> assign(:rework_pct, rework_pct)
    |> assign(:rework_cost, if(rework_data, do: rework_data.cost, else: 0.0))
  end

  defp filter_costs_by_range(costs, nil), do: costs

  defp filter_costs_by_range(costs, hours) do
    cutoff = DateTime.shift(DateTime.utc_now(), hour: -hours)
    Enum.filter(costs, fn c -> c[:recorded_at] && DateTime.compare(c.recorded_at, cutoff) != :lt end)
  end

  # Compute hours the factory was actively running missions within the range.
  # Uses the union of [inserted_at, updated_at] spans for missions that overlap the window.
  defp compute_active_hours(missions, range_hours) do
    now = DateTime.utc_now()
    window_start = if range_hours, do: DateTime.shift(now, hour: -range_hours), else: nil

    spans =
      missions
      |> Enum.filter(&(&1.status in ["active", "completed", "failed"]))
      |> Enum.map(fn m ->
        start = m[:inserted_at] || now
        stop = if m.status == "active", do: now, else: m[:updated_at] || now

        # Clamp to the selected range window
        start = if window_start && DateTime.compare(start, window_start) == :lt, do: window_start, else: start
        stop = if DateTime.compare(stop, now) == :gt, do: now, else: stop

        {start, stop}
      end)
      |> Enum.filter(fn {start, stop} -> DateTime.compare(start, stop) != :gt end)
      |> Enum.sort_by(fn {start, _} -> DateTime.to_unix(start) end)

    # Merge overlapping spans and sum total seconds
    merged_seconds =
      Enum.reduce(spans, {0, nil, nil}, fn {s, e}, {total, cur_start, cur_end} ->
        cond do
          is_nil(cur_start) ->
            {total, s, e}

          DateTime.compare(s, cur_end) != :gt ->
            # Overlapping — extend current span
            new_end = if DateTime.compare(e, cur_end) == :gt, do: e, else: cur_end
            {total, cur_start, new_end}

          true ->
            # Gap — flush current span, start new one
            {total + DateTime.diff(cur_end, cur_start, :second), s, e}
        end
      end)
      |> then(fn {total, cur_start, cur_end} ->
        if cur_start, do: total + DateTime.diff(cur_end, cur_start, :second), else: total
      end)

    # Convert to hours (minimum 0.01 to avoid division by zero display)
    max(merged_seconds / 3600.0, 0.0)
  end

  defp compute_summary(costs) do
    by_model = group_costs_by(costs, & &1[:model])
    by_category = group_costs_by(costs, & &1[:category])
    by_phase = group_costs_by(costs, & &1[:phase])
    by_phase_type = group_costs_by(costs, & &1[:phase_type])

    %{
      total_cost: costs |> Enum.map(&(&1[:cost_usd] || 0.0)) |> Enum.sum() |> to_float(),
      total_input_tokens: costs |> Enum.map(&(&1[:input_tokens] || 0)) |> Enum.sum(),
      total_output_tokens: costs |> Enum.map(&(&1[:output_tokens] || 0)) |> Enum.sum(),
      total_cache_read_tokens: costs |> Enum.map(&(&1[:cache_read_tokens] || 0)) |> Enum.sum(),
      total_cache_write_tokens: costs |> Enum.map(&(&1[:cache_write_tokens] || 0)) |> Enum.sum(),
      by_model: by_model,
      by_category: by_category,
      by_phase: by_phase,
      by_phase_type: by_phase_type
    }
  end

  defp group_costs_by(costs, key_fn) do
    costs
    |> Enum.group_by(key_fn)
    |> Map.delete(nil)
    |> Map.new(fn {k, group} ->
      {k, %{
        cost: group |> Enum.map(&(&1[:cost_usd] || 0.0)) |> Enum.sum() |> to_float(),
        input_tokens: group |> Enum.map(&(&1[:input_tokens] || 0)) |> Enum.sum(),
        output_tokens: group |> Enum.map(&(&1[:output_tokens] || 0)) |> Enum.sum()
      }}
    end)
  end

  defp range_config("1h"), do: {1, 12}
  defp range_config("4h"), do: {4, 16}
  defp range_config("8h"), do: {8, 16}
  defp range_config("Today"), do: {hours_since_midnight(), max(hours_since_midnight(), 1)}
  defp range_config("24h"), do: {24, 24}
  defp range_config("7d"), do: {168, 28}
  defp range_config("30d"), do: {720, 30}
  defp range_config("All"), do: {nil, 24}
  defp range_config(_), do: {24, 24}

  defp hours_since_midnight do
    now = DateTime.utc_now()
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    max(DateTime.diff(now, midnight, :hour), 1)
  end

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
    bucket_seconds = max(div(hours * 3600, buckets), 1)
    window_start = DateTime.shift(now, second: -(buckets * bucket_seconds))

    # Single pass: bucket each cost by time offset from now
    empty = Map.new(0..(buckets - 1), &{&1, {0.0, 0}})

    filled =
      Enum.reduce(costs, empty, fn c, acc ->
        case c[:recorded_at] do
          nil ->
            acc

          ts ->
            diff = DateTime.diff(now, ts, :second)

            if diff >= 0 and DateTime.compare(ts, window_start) != :lt do
              idx = buckets - 1 - min(div(diff, bucket_seconds), buckets - 1)
              {cost, tokens} = Map.get(acc, idx, {0.0, 0})
              Map.put(acc, idx, {cost + (c[:cost_usd] || 0.0), tokens + (c[:input_tokens] || 0) + (c[:output_tokens] || 0)})
            else
              acc
            end
        end
      end)

    bucket_hours = max(div(hours, buckets), 1)

    Enum.map(0..(buckets - 1), fn i ->
      {cost, tokens} = Map.get(filled, i, {0.0, 0})
      reverse_i = buckets - 1 - i

      label = cond do
        reverse_i == 0 -> "now"
        bucket_hours >= 24 -> "#{div(reverse_i * bucket_hours, 24)}d"
        true -> "#{reverse_i * bucket_hours}h"
      end

      %{label: label, cost: cost, tokens: tokens}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div id="costs-session" phx-hook="SessionStore" data-store-key="costs_range"></div>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">Cost Tracking</h1>
        <div style="display:flex; align-items:center; gap:0.5rem">
          <div style="display:flex; gap:2px">
            <%= for label <- @range_options do %>
              <button
                phx-click="set_range"
                phx-value-range={label}
                style={"padding:0.25rem 0.6rem; font-size:0.7rem; border-radius:4px; border:1px solid #{if @trend_range == label, do: "#58a6ff", else: "#30363d"}; background:#{if @trend_range == label, do: "#1f6feb33", else: "transparent"}; color:#{if @trend_range == label, do: "#58a6ff", else: "#8b949e"}; cursor:pointer"}
              >
                {label}
              </button>
            <% end %>
          </div>
          <button phx-click="refresh" class="btn btn-grey" style="font-size:0.8rem">Refresh</button>
        </div>
      </div>

      <%!-- Row 1: Gauges + Key Metrics --%>
      <div style="display:grid; grid-template-columns: repeat(3, 1fr); gap:0.75rem; margin-bottom:0.75rem">
        <%!-- Total Spend Gauge --%>
        <div class="card" style="display:flex; align-items:center; gap:1rem; padding:1rem">
          <div>
            <.gauge pct={@budget_pct} color={budget_gauge_color(@budget_pct)} />
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
            <% burn_pct = if @total_budget > 0, do: min(@burn_rate / max(0.01, @total_budget / 24) * 100, 100), else: 0.0 %>
            <.gauge pct={burn_pct} color={burn_color(@burn_rate)} />
          </div>
          <div>
            <div class="card-label">Burn Rate</div>
            <div class={"card-value #{if @burn_rate > 1.0, do: "red", else: "yellow"}"} style="font-size:1.4rem">
              {format_cost(@burn_rate, 2)}
            </div>
            <% hrs = Float.round(@active_hours, 1) %>
            <div style="font-size:0.7rem; color:#8b949e">per active hour ({hrs}h runtime)</div>
          </div>
        </div>

        <%!-- Cache Hit Gauge --%>
        <div class="card" style="display:flex; align-items:center; gap:1rem; padding:1rem">
          <div>
            <.gauge pct={@cache_hit_pct} color={cache_color(@cache_hit_pct)} />
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

      <%!-- Cost Trend --%>
      <div class="panel" style="margin-bottom:0.75rem">
        <div class="panel-title" style="margin-bottom:0.5rem">Cost Trend</div>
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

      <%!-- Two-column: Productive/Overhead + By Model --%>
      <div style="display:grid; grid-template-columns: 1fr 1fr; gap:0.75rem; margin-bottom:0.75rem">
        <%!-- Productive vs Overhead — horizontal stacked bar --%>
        <div class="panel" style="margin-bottom:0">
          <div class="panel-title" style="margin-bottom:0.5rem">Productive vs Overhead</div>
          <%= if @summary.by_phase_type == %{} do %>
            <div class="empty">No cost data recorded yet.</div>
          <% else %>
            <%!-- Stacked horizontal bar: productive (green) + overhead (yellow) + rework (red) --%>
            <div style="display:flex; height:32px; overflow:hidden; margin: 0.25rem -1.25rem 0.75rem -1.25rem">
              <%= if @prod_pct > 0 do %>
                <div style={"width:#{@prod_pct}%; background:#3fb950; display:flex; align-items:center; justify-content:center; font-size:0.65rem; font-weight:600; color:#0d1117; min-width:#{if @prod_pct > 8, do: "0", else: "30px"}"}>
                  {if @prod_pct > 8, do: "#{@prod_pct}%", else: ""}
                </div>
              <% end %>
              <%= if @overhead_pct > 0 do %>
                <div style={"width:#{@overhead_pct}%; background:#d29922; display:flex; align-items:center; justify-content:center; font-size:0.65rem; font-weight:600; color:#0d1117; min-width:#{if @overhead_pct > 8, do: "0", else: "30px"}"}>
                  {if @overhead_pct > 8, do: "#{@overhead_pct}%", else: ""}
                </div>
              <% end %>
              <%= if @rework_pct > 0 do %>
                <div style={"width:#{@rework_pct}%; background:#f85149; display:flex; align-items:center; justify-content:center; font-size:0.65rem; font-weight:600; color:#0d1117; min-width:#{if @rework_pct > 8, do: "0", else: "30px"}"}>
                  {if @rework_pct > 8, do: "#{@rework_pct}%", else: ""}
                </div>
              <% end %>
              <% unknown_pct = max(100.0 - @prod_pct - @overhead_pct - @rework_pct, 0) %>
              <%= if unknown_pct > 1 do %>
                <div style={"width:#{unknown_pct}%; background:#30363d"}></div>
              <% end %>
            </div>
            <%!-- Legend --%>
            <div style="display:flex; gap:1rem; font-size:0.75rem; flex-wrap:wrap">
              <div style="display:flex; align-items:center; gap:0.3rem">
                <div style="width:10px; height:10px; border-radius:2px; background:#3fb950"></div>
                <span style="color:#3fb950; font-weight:600">Productive</span>
                <span style="color:#8b949e">{format_cost(@prod_cost)} ({@prod_pct}%)</span>
              </div>
              <div style="display:flex; align-items:center; gap:0.3rem">
                <div style="width:10px; height:10px; border-radius:2px; background:#d29922"></div>
                <span style="color:#d29922; font-weight:600">Overhead</span>
                <span style="color:#8b949e">{format_cost(@overhead_cost)} ({@overhead_pct}%)</span>
              </div>
              <%= if @rework_pct > 0 do %>
                <div style="display:flex; align-items:center; gap:0.3rem">
                  <div style="width:10px; height:10px; border-radius:2px; background:#f85149"></div>
                  <span style="color:#f85149; font-weight:600">Rework</span>
                  <span style="color:#8b949e">{format_cost(@rework_cost)} ({@rework_pct}%)</span>
                </div>
              <% end %>
            </div>
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

      <%!-- Two-column: Mission Budgets + By Phase --%>
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

  # -- SVG Gauge (function component) ------------------------------------------

  attr :pct, :float, required: true
  attr :color, :string, required: true

  defp gauge(assigns) do
    pct = min(max(assigns.pct, 0), 100)
    arc_pct = pct / 100.0
    angle = :math.pi * (1.0 - arc_pct)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:arc_pct, arc_pct)
      |> assign(:ex, Float.round(60 + 45 * :math.cos(angle), 1))
      |> assign(:ey, Float.round(60 - 45 * :math.sin(angle), 1))
      |> assign(:large, if(arc_pct > 0.5, do: "1", else: "0"))

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
  defp phase_type_color("rework"), do: "#f85149"
  defp phase_type_color(_), do: "#8b949e"

  @overhead_phases ~w(review validation simplify scoring orchestration)
  defp phase_to_type(phase) when phase in @overhead_phases, do: "overhead"
  defp phase_to_type(_), do: "productive"

  # Enum.sum([]) returns 0 (integer); Float.round requires a float
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: 0.0
end
