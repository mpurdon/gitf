defmodule Hive.Dashboard.OverviewLive do
  @moduledoc """
  Main dashboard overview showing key metrics at a glance.

  Displays active bee count, quest count, total cost, and recent
  waggle messages. Subscribes to PubSub for live updates when new
  waggles arrive.
  """

  use Phoenix.LiveView

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to all waggle traffic for live updates
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
    quests = Hive.Quests.list()
    cost_summary = Hive.Costs.summary()
    recent_waggles = Hive.Waggle.list(limit: 5)

    active_bees = Enum.count(bees, &(&1.status in ["working", "starting"]))
    active_quests = Enum.count(quests, &(&1.status == "active"))
    
    # Context monitoring
    bees_with_context = Enum.filter(bees, &Map.has_key?(&1, :context_percentage))
    avg_context = if bees_with_context != [] do
      Enum.sum(Enum.map(bees_with_context, &(&1.context_percentage || 0.0))) / length(bees_with_context)
    else
      0.0
    end
    high_context_bees = Enum.count(bees_with_context, &((&1.context_percentage || 0) > 40))
    
    # Verification stats
    jobs = Hive.Jobs.list()
    verified_jobs = Enum.count(jobs, &(Map.get(&1, :verification_status) == "passed"))
    failed_verification = Enum.count(jobs, &(Map.get(&1, :verification_status) == "failed"))
    pending_verification = Enum.count(jobs, &(Map.get(&1, :verification_status) == "pending" and &1.status == "done"))

    # Quest phases
    research_quests = Enum.count(quests, &(Map.get(&1, :current_phase) == "research"))
    planning_quests = Enum.count(quests, &(Map.get(&1, :current_phase) == "planning"))
    implementation_quests = Enum.count(quests, &(Map.get(&1, :current_phase) == "implementation"))

    socket
    |> assign(:page_title, "Overview")
    |> assign(:current_path, "/")
    |> assign(:bee_count, length(bees))
    |> assign(:active_bees, active_bees)
    |> assign(:quest_count, length(quests))
    |> assign(:active_quests, active_quests)
    |> assign(:total_cost, cost_summary.total_cost)
    |> assign(:total_input_tokens, cost_summary.total_input_tokens)
    |> assign(:total_output_tokens, cost_summary.total_output_tokens)
    |> assign(:recent_waggles, recent_waggles)
    |> assign(:active_processes, safe_active_count())
    |> assign(:avg_context, avg_context)
    |> assign(:high_context_bees, high_context_bees)
    |> assign(:verified_jobs, verified_jobs)
    |> assign(:failed_verification, failed_verification)
    |> assign(:pending_verification, pending_verification)
    |> assign(:research_quests, research_quests)
    |> assign(:planning_quests, planning_quests)
    |> assign(:implementation_quests, implementation_quests)
  end

  defp safe_active_count do
    Hive.CombSupervisor.active_count()
  rescue
    _ -> 0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={Hive.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <h1 class="page-title">Dashboard Overview</h1>

      <div class="cards">
        <div class="card">
          <div class="card-label">Total Bees</div>
          <div class="card-value blue">{@bee_count}</div>
          <div class="card-label" style="margin-top:0.25rem">{@active_bees} active</div>
        </div>
        <div class="card">
          <div class="card-label">Quests</div>
          <div class="card-value yellow">{@quest_count}</div>
          <div class="card-label" style="margin-top:0.25rem">{@active_quests} active</div>
        </div>
        <div class="card">
          <div class="card-label">Total Cost</div>
          <div class="card-value green">{format_cost(@total_cost)}</div>
          <div class="card-label" style="margin-top:0.25rem">{format_tokens(@total_input_tokens + @total_output_tokens)} tokens</div>
        </div>
        <div class="card">
          <div class="card-label">Live Processes</div>
          <div class="card-value">{@active_processes}</div>
          <div class="card-label" style="margin-top:0.25rem">under CombSupervisor</div>
        </div>
      </div>

      <div class="cards">
        <div class="card">
          <div class="card-label">Context Usage</div>
          <div class={"card-value #{if @avg_context > 40, do: "orange", else: "blue"}"}>
            {Float.round(@avg_context, 1)}%
          </div>
          <div class="card-label" style="margin-top:0.25rem">
            {if @high_context_bees > 0, do: "#{@high_context_bees} bees >40%", else: "all bees healthy"}
          </div>
        </div>
        <div class="card">
          <div class="card-label">Verification</div>
          <div class={"card-value #{if @failed_verification > 0, do: "red", else: "green"}"}>
            {@verified_jobs}
          </div>
          <div class="card-label" style="margin-top:0.25rem">
            {if @failed_verification > 0, do: "#{@failed_verification} failed", else: "#{@pending_verification} pending"}
          </div>
        </div>
        <div class="card">
          <div class="card-label">Quest Phases</div>
          <div class="card-value purple">{@implementation_quests}</div>
          <div class="card-label" style="margin-top:0.25rem">
            R:{@research_quests} P:{@planning_quests} I:{@implementation_quests}
          </div>
        </div>
      </div>

      <div class="panel">
        <div class="panel-title">Recent Waggles</div>
        <%= if @recent_waggles == [] do %>
          <div class="empty">No waggle messages yet.</div>
        <% else %>
          <%= for waggle <- @recent_waggles do %>
            <div class={"waggle-item #{unless waggle.read, do: "waggle-unread"}"}>
              <div class="waggle-subject">{waggle.subject || "(no subject)"}</div>
              <div class="waggle-meta">
                {waggle.from} &rarr; {waggle.to}
                &middot;
                {format_timestamp(waggle.inserted_at)}
                &middot;
                <span class={"badge #{if waggle.read, do: "badge-grey", else: "badge-blue"}"}>
                  {if waggle.read, do: "read", else: "unread"}
                </span>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </.live_component>
    """
  end

  defp format_cost(cost) when is_float(cost), do: "$#{:erlang.float_to_binary(cost, decimals: 4)}"
  defp format_cost(_), do: "$0.0000"

  defp format_tokens(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  defp format_tokens(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}K"
  end

  defp format_tokens(count), do: "#{count}"

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_), do: "-"
end
