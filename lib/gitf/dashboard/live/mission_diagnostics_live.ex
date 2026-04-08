defmodule GiTF.Dashboard.MissionDiagnosticsLive do
  @moduledoc "Mission diagnostics page — surfaces why missions/ops failed and provides recovery actions."

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        {:ok,
         socket
         |> assign(:page_title, "Diagnostics — #{Map.get(mission, :name, "Mission")}")
         |> assign(:current_path, "/dashboard/missions")
         |> assign(:mission, mission)
         |> assign(:selected_op, nil)
         |> assign(:analyzing, MapSet.new())
         |> assign(:suggested_strategies, %{})
         |> assign(:suggesting, MapSet.new())
         |> assign(:feedback_text, %{})
         |> load_diagnostics(id, mission)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Mission not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  defp load_diagnostics(socket, id, mission) do
    ops = GiTF.Ops.list(mission_id: id)
    failed_ops = Enum.filter(ops, &(Map.get(&1, :status) == "failed"))
    transitions = GiTF.Missions.get_phase_transitions(id)
    health = GiTF.Observability.Health.check()
    alerts = GiTF.Observability.Alerts.check_alerts()
    retry_chains = build_retry_chains(ops)
    analyses = load_existing_analyses(failed_ops)
    ghost_info = load_ghost_info(failed_ops)
    audit_data = load_audit_data(failed_ops)
    enriched = GiTF.EventStore.enriched_timeline(id)
    failure_info = Map.get(mission, :failure_info)

    first_failed = List.first(failed_ops)

    socket
    |> assign(:ops, ops)
    |> assign(:failed_ops, failed_ops)
    |> assign(:transitions, transitions)
    |> assign(:health, health)
    |> assign(:alerts, alerts)
    |> assign(:retry_chains, retry_chains)
    |> assign(:analyses, analyses)
    |> assign(:ghost_info, ghost_info)
    |> assign(:audit_data, audit_data)
    |> assign(:enriched_phases, enriched.phases)
    |> assign(:phase_costs, enriched.phase_costs)
    |> assign(:failure_info, failure_info)
    |> assign(:selected_op, first_failed && Map.get(first_failed, :id))
  end

  # -- Data loaders ----------------------------------------------------------

  defp build_retry_chains(ops) do
    by_id = Map.new(ops, &{&1.id, &1})

    ops
    |> Enum.filter(&Map.get(&1, :retry_of))
    |> Enum.reduce(%{}, fn op, acc ->
      root = find_retry_root(op, by_id)
      chain = Map.get(acc, root, [root]) |> then(&if(op.id in &1, do: &1, else: &1 ++ [op.id]))
      Map.put(acc, root, chain)
    end)
  end

  defp find_retry_root(op, by_id) do
    case Map.get(op, :retry_of) do
      nil ->
        op.id

      parent_id ->
        case Map.get(by_id, parent_id) do
          nil -> parent_id
          parent -> find_retry_root(parent, by_id)
        end
    end
  end

  defp load_existing_analyses(failed_ops) do
    Enum.reduce(failed_ops, %{}, fn op, acc ->
      results =
        GiTF.Archive.filter(:failure_analyses, fn entry ->
          Map.get(entry, :op_id) == op.id
        end)

      case results do
        [analysis | _] -> Map.put(acc, op.id, analysis)
        _ -> acc
      end
    end)
  end

  defp load_ghost_info(failed_ops) do
    Enum.reduce(failed_ops, %{}, fn op, acc ->
      case Map.get(op, :ghost_id) do
        nil ->
          acc

        ghost_id ->
          case GiTF.Ghosts.get(ghost_id) do
            {:ok, ghost} ->
              backup =
                try do
                  case GiTF.Backup.load(ghost_id) do
                    {:ok, data} when is_map(data) -> data
                    data when is_map(data) -> data
                    _ -> nil
                  end
                rescue
                  _ -> nil
                end

              Map.put(acc, op.id, %{ghost: ghost, checkpoint: backup})

            _ ->
              acc
          end
      end
    end)
  end

  defp load_audit_data(failed_ops) do
    Enum.reduce(failed_ops, %{}, fn op, acc ->
      results =
        GiTF.Archive.filter(:audit_results, fn entry ->
          Map.get(entry, :op_id) == op.id
        end)

      case results do
        [audit | _] -> Map.put(acc, op.id, audit)
        _ -> acc
      end
    end)
  end

  # -- Refresh ---------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, reload(socket)}
  end

  def handle_info({:waggle_received, _}, socket), do: {:noreply, reload(socket)}

  def handle_info({ref, {:analysis_result, op_id, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, analysis} ->
          socket
          |> update(:analyses, &Map.put(&1, op_id, analysis))
          |> update(:analyzing, &MapSet.delete(&1, op_id))

        {:error, reason} ->
          socket
          |> update(:analyzing, &MapSet.delete(&1, op_id))
          |> put_flash(:error, "Analysis failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_info({ref, {:strategy_result, op_id, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        strategy when is_atom(strategy) ->
          socket
          |> update(:suggested_strategies, &Map.put(&1, op_id, strategy))
          |> update(:suggesting, &MapSet.delete(&1, op_id))

        _ ->
          socket
          |> update(:suggesting, &MapSet.delete(&1, op_id))
          |> put_flash(:error, "Strategy suggestion failed")
      end

    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("select_op", %{"id" => op_id}, socket) do
    {:noreply, assign(socket, :selected_op, op_id)}
  end

  def handle_event("analyze", %{"id" => op_id}, socket) do
    Task.async(fn ->
      {:analysis_result, op_id, GiTF.Intel.FailureAnalysis.analyze_failure(op_id)}
    end)

    {:noreply, update(socket, :analyzing, &MapSet.put(&1, op_id))}
  end

  def handle_event("suggest_strategy", %{"id" => op_id}, socket) do
    failure_type = get_in(socket.assigns.analyses, [op_id, :failure_type]) || :unknown

    Task.async(fn ->
      strategy = GiTF.Intel.Retry.recommend_strategy(failure_type)
      {:strategy_result, op_id, strategy}
    end)

    {:noreply, update(socket, :suggesting, &MapSet.put(&1, op_id))}
  end

  def handle_event("retry_with_strategy", %{"id" => op_id}, socket) do
    case GiTF.Intel.Retry.retry_with_strategy(op_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Retry initiated.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reset_op", %{"id" => op_id}, socket) do
    feedback = Map.get(socket.assigns.feedback_text, op_id)

    case GiTF.Ops.reset(op_id, feedback) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Op reset.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  def handle_event("revive_op", %{"id" => op_id, "ghost_id" => ghost_id}, socket) do
    case GiTF.Ops.revive(op_id, ghost_id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Op revived.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revive failed: #{inspect(reason)}")}
    end
  end

  def handle_event("update_feedback", %{"id" => op_id, "value" => value}, socket) do
    {:noreply, update(socket, :feedback_text, &Map.put(&1, op_id, value))}
  end

  defp reload(socket) do
    id = socket.assigns.mission.id

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        socket
        |> assign(:mission, mission)
        |> load_diagnostics(id, mission)

      {:error, _} ->
        socket
    end
  end

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <%!-- Header --%>
      <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:1.25rem; flex-wrap:wrap; gap:0.75rem">
        <div>
          <h1 class="page-title" style="margin-bottom:0.25rem">
            Diagnostics: {Map.get(@mission, :name, "Mission")}
          </h1>
          <div style="margin-top:0.5rem; display:flex; gap:0.5rem; align-items:center">
            <span class={"badge #{status_badge(Map.get(@mission, :status, "unknown"))}"}>
              {Map.get(@mission, :status, "unknown")}
            </span>
            <span class={"badge #{phase_badge(Map.get(@mission, :current_phase, "pending"))}"}>
              {Map.get(@mission, :current_phase, "pending")}
            </span>
            <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">
              {short_id(@mission.id)}
            </span>
          </div>
        </div>
        <a href={"/dashboard/missions/#{@mission.id}"} class="btn btn-grey">Back to Mission</a>
      </div>

      <%!-- Health Summary Cards --%>
      <div class="cards">
        <div class="card">
          <div class="card-label">Status</div>
          <div class="card-value">
            <span class={"badge #{status_badge(Map.get(@mission, :status, "unknown"))}"} style="font-size:1rem">
              {Map.get(@mission, :status, "unknown")}
            </span>
          </div>
        </div>
        <div class="card">
          <div class="card-label">Failed Ops</div>
          <div class={"card-value #{if length(@failed_ops) > 0, do: "red", else: "green"}"}>
            {length(@failed_ops)}
          </div>
        </div>
        <div class="card">
          <div class="card-label">Recovery Cycles</div>
          <div class="card-value yellow">
            {recovery_cycles(@mission)}
          </div>
        </div>
        <div class="card">
          <div class="card-label">System Health</div>
          <div class={"card-value #{if @health.status == :healthy, do: "green", else: "yellow"}"}>
            {if @health.status == :healthy, do: "Healthy", else: "Degraded"}
          </div>
        </div>
      </div>

      <%!-- Phase Timeline --%>
      <div class="panel">
        <div class="panel-title">Phase Timeline</div>
        <%= if @transitions == [] do %>
          <div class="empty">No phase transitions recorded.</div>
        <% else %>
          <div class="timeline">
            <%= for {t, idx} <- Enum.with_index(@transitions) do %>
              <div class={"timeline-item #{if idx == length(@transitions) - 1 && stuck?(@mission, t), do: "timeline-item-stuck"}"}>
                <div class="timeline-dot"></div>
                <div class="timeline-content">
                  <div style="display:flex; gap:0.5rem; align-items:center; flex-wrap:wrap">
                    <span class="badge badge-grey">{Map.get(t, :from_phase, "?")}</span>
                    <span style="color:#8b949e">&rarr;</span>
                    <span class={"badge #{phase_badge(Map.get(t, :to_phase, "?"))}"}>
                      {Map.get(t, :to_phase, "?")}
                    </span>
                    <span style="font-size:0.75rem; color:#484f58">
                      {format_timestamp(Map.get(t, :inserted_at))}
                    </span>
                  </div>
                  <%= if Map.get(t, :reason) do %>
                    <div style="margin-top:0.35rem; font-size:0.85rem; color:#8b949e">
                      {Map.get(t, :reason)}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Failure Classification --%>
      <%= if @failure_info do %>
        <div class="panel" style="margin-bottom:1rem; border-left:3px solid #f85149">
          <div class="panel-title">Failure Classification</div>
          <div style="display:flex; gap:1rem; flex-wrap:wrap; align-items:center">
            <span class="badge badge-red" style="font-size:0.9rem">{@failure_info[:failure_type] || "unknown"}</span>
            <span style="color:#8b949e">during <strong>{@failure_info[:failure_phase] || "?"}</strong> phase</span>
            <%= if length(@failure_info[:failed_op_ids] || []) > 0 do %>
              <span style="color:#8b949e">{length(@failure_info[:failed_op_ids])} failed ops</span>
            <% end %>
          </div>
          <div style="margin-top:0.5rem; font-size:0.85rem; color:#c9d1d9">{@failure_info[:failure_reason]}</div>
        </div>
      <% end %>

      <%!-- Phase Durations & Costs --%>
      <%= if @enriched_phases != [] do %>
        <div class="panel" style="margin-bottom:1rem">
          <div class="panel-title">Phase Durations & Costs</div>
          <table>
            <thead>
              <tr>
                <th>Phase</th>
                <th style="text-align:right">Duration</th>
                <th style="text-align:right">Cost</th>
                <th style="text-align:right">Tokens</th>
              </tr>
            </thead>
            <tbody>
              <%= for p <- @enriched_phases do %>
                <tr>
                  <td>
                    <span class={"badge #{phase_badge(p.phase)}"}>{p.phase}</span>
                  </td>
                  <td style="text-align:right; font-family:monospace; font-size:0.85rem">
                    {format_duration(p[:duration_s])}
                  </td>
                  <td style="text-align:right; font-family:monospace; font-size:0.85rem">
                    {format_cost(p[:cost_usd] || 0)}
                  </td>
                  <td style="text-align:right; font-family:monospace; font-size:0.85rem">
                    {format_tokens(p[:tokens] || 0)}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <%!-- Productive vs Overhead --%>
          <%= if @phase_costs.by_phase_type != %{} do %>
            <div style="margin-top:0.75rem; display:flex; gap:1.5rem; font-size:0.85rem">
              <%= if prod = @phase_costs.by_phase_type["productive"] do %>
                <span style="color:#3fb950">Productive: {format_cost(prod.cost)}</span>
              <% end %>
              <%= if ovhd = @phase_costs.by_phase_type["overhead"] do %>
                <span style="color:#d29922">Overhead: {format_cost(ovhd.cost)}</span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Failed Ops Diagnostics --%>
      <%= if @failed_ops != [] do %>
        <div class="panel">
          <div class="panel-title">Failed Ops Diagnostics ({length(@failed_ops)})</div>

          <%!-- Tab bar for multiple failed ops --%>
          <%= if length(@failed_ops) > 1 do %>
            <div class="tab-bar">
              <%= for op <- @failed_ops do %>
                <div
                  class={"tab #{if @selected_op == op.id, do: "tab-active"}"}
                  phx-click="select_op"
                  phx-value-id={op.id}
                >
                  {Map.get(op, :title, short_id(op.id))}
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Selected op detail --%>
          <%= for op <- @failed_ops, op.id == @selected_op do %>
            <%!-- Identity --%>
            <div style="margin-bottom:1rem">
              <div style="display:flex; gap:0.5rem; align-items:center; flex-wrap:wrap; margin-bottom:0.5rem">
                <strong style="color:#f0f6fc">{Map.get(op, :title, "Untitled Op")}</strong>
                <a href={"/dashboard/ops/#{op.id}"} style="font-family:monospace; font-size:0.8rem">{short_id(op.id)}</a>
                <span class="badge badge-red">failed</span>
                <%= if Map.get(op, :phase) do %>
                  <span class={"badge #{phase_badge(op.phase)}"}>{op.phase}</span>
                <% end %>
                <%= if Map.get(op, :ghost_id) do %>
                  <span style="font-size:0.8rem; color:#8b949e">Ghost: {short_id(op.ghost_id)}</span>
                <% end %>
                <%= if Map.get(op, :retry_count, 0) > 0 do %>
                  <span class="badge badge-orange">retry #{Map.get(op, :retry_count)}</span>
                <% end %>
              </div>
            </div>

            <%!-- Error Message --%>
            <%= if Map.get(op, :error_message) do %>
              <div style="margin-bottom:1rem">
                <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">Error</div>
                <div class="pre-block" style="border-color:#f8514955">{op.error_message}</div>
              </div>
            <% end %>

            <%!-- Failure Analysis --%>
            <div style="margin-bottom:1rem">
              <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">Failure Analysis</div>
              <%= if analysis = Map.get(@analyses, op.id) do %>
                <div style="display:flex; gap:0.5rem; align-items:center; margin-bottom:0.5rem; flex-wrap:wrap">
                  <span class={"badge #{failure_type_badge(Map.get(analysis, :failure_type))}"}>{Map.get(analysis, :failure_type, "unknown")}</span>
                  <%= if count = Map.get(analysis, :similar_count) do %>
                    <span style="font-size:0.8rem; color:#8b949e">{count} similar failures</span>
                  <% end %>
                </div>
                <%= if Map.get(analysis, :root_cause) do %>
                  <div style="font-size:0.85rem; color:#c9d1d9; margin-bottom:0.5rem">{analysis.root_cause}</div>
                <% end %>
                <%= if suggestions = Map.get(analysis, :suggestions) do %>
                  <ul style="margin:0; padding-left:1.25rem; font-size:0.85rem; color:#8b949e">
                    <%= for s <- List.wrap(suggestions) do %>
                      <li style="margin-bottom:0.25rem">{s}</li>
                    <% end %>
                  </ul>
                <% end %>
              <% else %>
                <%= if MapSet.member?(@analyzing, op.id) do %>
                  <div style="display:flex; align-items:center; gap:0.5rem; color:#8b949e">
                    <span class="loading-spinner" style="width:14px;height:14px;border-width:2px"></span>
                    Analyzing...
                  </div>
                <% else %>
                  <button phx-click="analyze" phx-value-id={op.id} class="btn btn-blue" style="font-size:0.8rem">
                    Analyze
                  </button>
                <% end %>
              <% end %>
            </div>

            <%!-- Retry Chain --%>
            <%= if chain = find_retry_chain(@retry_chains, op.id) do %>
              <div style="margin-bottom:1rem">
                <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">Retry Chain</div>
                <div class="retry-chain">
                  <%= for {node_id, idx} <- Enum.with_index(chain) do %>
                    <%= if idx > 0 do %>
                      <div class="retry-arrow">&rarr;</div>
                    <% end %>
                    <% node_op = Enum.find(@ops, &(&1.id == node_id)) %>
                    <div class={"retry-node #{if node_id == op.id, do: "retry-node-current"}"}>
                      <a href={"/dashboard/ops/#{node_id}"} style="font-family:monospace; font-size:0.75rem">
                        {short_id(node_id)}
                      </a>
                      <%= if node_op do %>
                        <span class={"badge #{status_badge(Map.get(node_op, :status, "unknown"))}"} style="font-size:0.65rem">
                          {Map.get(node_op, :status, "?")}
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Ghost Context --%>
            <%= if ghost_data = Map.get(@ghost_info, op.id) do %>
              <div style="margin-bottom:1rem">
                <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">Ghost Context</div>
                <dl class="metadata-grid">
                  <dt>Status</dt>
                  <dd><span class={"badge #{status_badge(Map.get(ghost_data.ghost, :status, "unknown"))}"}>{Map.get(ghost_data.ghost, :status, "unknown")}</span></dd>
                  <dt>Model</dt>
                  <dd>{Map.get(ghost_data.ghost, :assigned_model, "-")}</dd>
                  <dt>Context</dt>
                  <dd>{Map.get(ghost_data.ghost, :context_tokens_used, "-")}</dd>
                </dl>
                <%= if cp = ghost_data.checkpoint do %>
                  <div style="margin-top:0.5rem">
                    <dl class="metadata-grid">
                      <dt>Tool Calls</dt><dd>{Map.get(cp, :tool_calls, 0)}</dd>
                      <dt>Files Modified</dt><dd>{length(Map.get(cp, :files_modified, []))}</dd>
                      <dt>Errors</dt><dd>{Map.get(cp, :error_count, 0)}</dd>
                      <dt>Progress</dt><dd>{Map.get(cp, :progress_summary, "-")}</dd>
                      <dt>Pending</dt><dd>{Map.get(cp, :pending_work, "-")}</dd>
                    </dl>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Audit Results --%>
            <%= if audit = Map.get(@audit_data, op.id) do %>
              <div style="margin-bottom:1rem">
                <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">Audit Results</div>
                <div class="grid-2">
                  <%= for {label, key} <- [{"Quality", :quality_score}, {"Static", :static_score}, {"Security", :security_score}] do %>
                    <%= if score = Map.get(audit, key) do %>
                      <div>
                        <div style="font-size:0.8rem; color:#8b949e; margin-bottom:0.25rem">{label}: {score}/100</div>
                        <div class="score-bar">
                          <div class="score-bar-fill" style={"width:#{score}%; background:#{score_color(score)}"}></div>
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                </div>
                <%= if Map.get(audit, :issue_count) do %>
                  <div style="margin-top:0.5rem; font-size:0.85rem; color:#8b949e">
                    Issues: {audit.issue_count} | Exit code: {Map.get(audit, :exit_code, "-")}
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Recovery Actions --%>
            <div style="border-top:1px solid #30363d; padding-top:1rem; margin-top:0.5rem">
              <div style="font-size:0.85rem; font-weight:600; color:#f0f6fc; margin-bottom:0.5rem">Recovery Actions</div>
              <div style="display:flex; gap:0.5rem; flex-wrap:wrap; align-items:flex-start">
                <%!-- Smart Retry --%>
                <%= if strategy = Map.get(@suggested_strategies, op.id) do %>
                  <div style="display:flex; flex-direction:column; gap:0.35rem">
                    <span style="font-size:0.8rem; color:#8b949e">Strategy: <strong style="color:#d29922">{strategy_label(strategy)}</strong></span>
                    <button phx-click="retry_with_strategy" phx-value-id={op.id} class="btn btn-green" style="font-size:0.8rem">
                      Confirm Retry
                    </button>
                  </div>
                <% else %>
                  <%= if MapSet.member?(@suggesting, op.id) do %>
                    <button class="btn btn-blue" disabled style="font-size:0.8rem">
                      <span class="loading-spinner" style="width:12px;height:12px;border-width:2px"></span>
                      Analyzing...
                    </button>
                  <% else %>
                    <button phx-click="suggest_strategy" phx-value-id={op.id} class="btn btn-blue" style="font-size:0.8rem">
                      Smart Retry
                    </button>
                  <% end %>
                <% end %>

                <%!-- Reset with feedback --%>
                <div style="display:flex; gap:0.35rem; align-items:flex-end">
                  <div>
                    <textarea
                      phx-keyup="update_feedback"
                      phx-value-id={op.id}
                      placeholder="Optional feedback..."
                      class="form-textarea"
                      style="min-height:34px; height:34px; width:200px; font-size:0.8rem; padding:0.35rem 0.5rem"
                    >{Map.get(@feedback_text, op.id, "")}</textarea>
                  </div>
                  <button phx-click="reset_op" phx-value-id={op.id} class="btn btn-grey" style="font-size:0.8rem">
                    Reset
                  </button>
                </div>

                <%!-- Revive --%>
                <%= if ghost_data = Map.get(@ghost_info, op.id) do %>
                  <%= if ghost_data.checkpoint do %>
                    <button
                      phx-click="revive_op"
                      phx-value-id={op.id}
                      phx-value-ghost_id={Map.get(op, :ghost_id)}
                      class="btn btn-purple"
                      style="font-size:0.8rem"
                    >
                      Revive
                    </button>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- System Health Panel --%>
      <div class="panel">
        <div class="panel-title">System Health</div>
        <div class="grid-2">
          <div>
            <%= for {component, status} <- Map.get(@health, :checks, %{}) do %>
              <div style="display:flex; justify-content:space-between; padding:0.35rem 0; border-bottom:1px solid #21262d; font-size:0.85rem">
                <span>{component}</span>
                <span class={"badge #{if status == :ok, do: "badge-green", else: "badge-red"}"}>
                  {status}
                </span>
              </div>
            <% end %>
          </div>
          <div>
            <%= if @alerts != [] do %>
              <%= for {rule, message} <- @alerts do %>
                <div style="background:#d2992215; border:1px solid #d2992233; border-radius:6px; padding:0.5rem 0.75rem; margin-bottom:0.5rem; font-size:0.85rem">
                  <strong style="color:#d29922">{rule}</strong>
                  <div style="color:#8b949e; margin-top:0.15rem">{message}</div>
                </div>
              <% end %>
            <% else %>
              <div class="empty" style="padding:0.5rem 0">No active alerts.</div>
            <% end %>
          </div>
        </div>
      </div>
    </.live_component>
    """
  end

  # -- Helpers ---------------------------------------------------------------

  defp format_duration(nil), do: "-"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp recovery_cycles(mission) do
    (Map.get(mission, :redesign_count, 0) || 0) +
      (Map.get(mission, :replan_count, 0) || 0) +
      (Map.get(mission, :validation_fix_count, 0) || 0)
  end

  defp stuck?(mission, transition) do
    status = Map.get(mission, :status)
    to_phase = Map.get(transition, :to_phase)
    current_phase = Map.get(mission, :current_phase)
    status not in ["completed", "killed"] and to_phase == current_phase
  end

  defp find_retry_chain(retry_chains, op_id) do
    Enum.find_value(retry_chains, fn {_root, chain} ->
      if op_id in chain, do: chain
    end)
  end

  defp score_color(score) when score >= 80, do: "#3fb950"
  defp score_color(score) when score >= 50, do: "#d29922"
  defp score_color(_), do: "#f85149"
end
