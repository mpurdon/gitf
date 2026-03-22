defmodule GiTF.Dashboard.MissionDetailLive do
  @moduledoc "Mission detail page with phase stepper, ops, and contextual actions."

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(5)

  # Derive display phases from the orchestrator's canonical list,
  # adding "pending" and "completed" bookends, removing "awaiting_approval" (shown as sync)
  @phases (["pending"] ++
    (GiTF.Major.Orchestrator.phases() -- ["awaiting_approval"]) ++
    ["completed"])

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:monitor")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        ops = GiTF.Ops.list(mission_id: id)

        {:ok,
         socket
         |> assign(:page_title, Map.get(mission, :name, "Mission"))
         |> assign(:current_path, "/dashboard/missions")
         |> assign(:mission, mission)
         |> assign(:ops, ops)
         |> assign(:selected_phase, nil)
         |> assign(:artifact, nil)
         |> assign(:report, nil)
         |> assign(:report_loading, false)
         |> assign(:sectors, load_sectors())}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Mission not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, reload(socket)}
  end

  def handle_info({:waggle_received, _}, socket), do: {:noreply, reload(socket)}

  def handle_info({ref, {:report, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, report} ->
        formatted = GiTF.Report.format(report)
        {:noreply, assign(socket, report: formatted, report_loading: false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:report_loading, false)
         |> put_flash(:error, "Report failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start", _params, socket) do
    case GiTF.Major.Orchestrator.start_quest(socket.assigns.mission.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mission started.")
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("assign_sector", %{"sector_id" => sector_id}, socket) do
    mission = socket.assigns.mission

    case GiTF.Archive.get(:missions, mission.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mission not found")}

      record ->
        GiTF.Archive.put(:missions, Map.put(record, :sector_id, sector_id))
        {:noreply, socket |> put_flash(:info, "Sector assigned.") |> reload()}
    end
  end

  def handle_event("remove", _params, socket) do
    mission_id = socket.assigns.mission.id

    # Kill first to clean up all child artifacts (ops, ghosts, shells, deps)
    # then delete residual data (links, events, costs, phase transitions)
    case GiTF.Missions.kill(mission_id) do
      :ok ->
        cleanup_mission_artifacts(mission_id)

        {:noreply,
         socket
         |> put_flash(:info, "Mission and all associated data removed.")
         |> push_navigate(to: "/dashboard/missions")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove: #{inspect(reason)}")}
    end
  end

  def handle_event("kill", _params, socket) do
    case GiTF.Missions.kill(socket.assigns.mission.id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Mission killed.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to kill: #{inspect(reason)}")}
    end
  end

  def handle_event("generate_report", _params, socket) do
    mission_id = socket.assigns.mission.id

    Task.async(fn ->
      {:report, GiTF.Report.generate(mission_id)}
    end)

    {:noreply, assign(socket, :report_loading, true)}
  end

  def handle_event("select_phase", %{"phase" => phase}, socket) do
    artifact = GiTF.Missions.get_artifact(socket.assigns.mission.id, phase)
    {:noreply, assign(socket, selected_phase: phase, artifact: artifact)}
  end

  def handle_event("reset_op", %{"id" => op_id}, socket) do
    case GiTF.Ops.reset(op_id, nil) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_op", %{"id" => op_id}, socket) do
    expanded = socket.assigns[:expanded_ops] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, op_id),
        do: MapSet.delete(expanded, op_id),
        else: MapSet.put(expanded, op_id)

    {:noreply, assign(socket, :expanded_ops, expanded)}
  end

  defp reload(socket) do
    id = socket.assigns.mission.id

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        ops = GiTF.Ops.list(mission_id: id)
        assign(socket, mission: mission, ops: ops, sectors: load_sectors())

      {:error, _} ->
        socket
    end
  end

  defp cleanup_mission_artifacts(mission_id) do
    # Clean up links referencing this mission's ghosts/ops
    GiTF.Archive.all(:links)
    |> Enum.filter(fn l ->
      String.contains?(l.body || "", mission_id) or
        String.contains?(l.from || "", "ghost-")
    end)
    |> Enum.each(fn l -> GiTF.Archive.delete(:links, l.id) end)

    # Clean up events for this mission
    GiTF.EventStore.list(mission_id: mission_id, limit: 500)
    |> Enum.each(fn e -> GiTF.Archive.delete(:events, e.id) end)

    # Clean up phase transitions
    GiTF.Archive.filter(:mission_phase_transitions, fn t -> t.mission_id == mission_id end)
    |> Enum.each(fn t -> GiTF.Archive.delete(:mission_phase_transitions, t.id) end)

    # Clean up approval requests
    GiTF.Archive.filter(:approval_requests, fn r -> r.mission_id == mission_id end)
    |> Enum.each(fn r -> GiTF.Archive.delete(:approval_requests, r.id) end)

    # Clean up costs for ghosts that worked on this mission's ops
    GiTF.Archive.filter(:costs, fn c ->
      case GiTF.Archive.get(:ghosts, c.ghost_id) do
        %{op_id: op_id} when is_binary(op_id) ->
          case GiTF.Archive.get(:ops, op_id) do
            %{mission_id: ^mission_id} -> true
            _ -> false
          end
        _ -> false
      end
    end)
    |> Enum.each(fn c -> GiTF.Archive.delete(:costs, c.id) end)
  rescue
    _ -> :ok
  end

  defp load_sectors do
    try do
      GiTF.Sector.list()
    rescue
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:expanded_ops, MapSet.new())
      |> Map.put(:phases, @phases)

    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <%!-- Header --%>
      <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:1.25rem; flex-wrap:wrap; gap:0.75rem">
        <div>
          <h1 class="page-title" style="margin-bottom:0.25rem">
            {Map.get(@mission, :name, "Mission")}
          </h1>
          <div style="color:#8b949e; font-size:0.85rem; max-width:600px">
            {Map.get(@mission, :goal, "")}
          </div>
          <div style="margin-top:0.5rem; display:flex; gap:0.5rem; align-items:center">
            <span class={"badge #{status_badge(Map.get(@mission, :status, "unknown"))}"}>
              {Map.get(@mission, :status, "unknown")}
            </span>
            <span class={"badge #{phase_badge(Map.get(@mission, :current_phase, "pending"))}"}>
              {Map.get(@mission, :current_phase, "pending")}
            </span>
            <span class={"badge #{if Map.get(@mission, :pipeline_mode) == "fast", do: "badge-yellow", else: "badge-purple"}"} style="font-size:0.65rem">
              {Map.get(@mission, :pipeline_mode, "pending") |> to_string() |> String.upcase()}
            </span>
            <%= if Map.get(@mission, :review_plan) do %>
              <span class="badge badge-purple" style="font-size:0.55rem">REVIEW</span>
            <% end %>
            <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">
              {short_id(@mission.id)}
            </span>
          </div>
        </div>
        <div style="display:flex; gap:0.5rem; flex-wrap:wrap">
          <!-- Sector assignment (if none assigned) -->
          <%= if is_nil(Map.get(@mission, :sector_id)) and @sectors != [] do %>
            <form phx-submit="assign_sector" style="display:flex; gap:0.5rem; align-items:center">
              <select name="sector_id" class="form-select" style="font-size:0.8rem; padding:0.3rem 0.5rem; min-width:150px">
                <%= for sector <- @sectors do %>
                  <option value={sector.id}>{sector.name}</option>
                <% end %>
              </select>
              <button type="submit" class="btn btn-blue" style="font-size:0.8rem; padding:0.3rem 0.6rem">Assign Sector</button>
            </form>
          <% end %>

          <%= case Map.get(@mission, :status, "pending") do %>
            <% "pending" -> %>
              <button phx-click="start" class="btn btn-green">Start Mission</button>
            <% "active" -> %>
              <%= if Map.get(@mission, :current_phase) == "planning" do %>
                <a href={"/dashboard/missions/#{@mission.id}/plan"} class="btn btn-purple">View Plans</a>
              <% end %>
              <button phx-click="kill" class="btn btn-red" data-confirm="Kill this mission?">Kill</button>
            <% "completed" -> %>
              <button phx-click="generate_report" class="btn btn-blue" disabled={@report_loading}>
                <%= if @report_loading do %>
                  <span class="loading-spinner" style="width:14px;height:14px;border-width:2px"></span>
                  Generating...
                <% else %>
                  Generate Report
                <% end %>
              </button>
            <% _ -> %>
          <% end %>
          <%= if Map.get(@mission, :status) == "failed" || Enum.any?(@ops, &(Map.get(&1, :status) == "failed")) do %>
            <a href={"/dashboard/missions/#{@mission.id}/diagnostics"} class="btn btn-red">Diagnose</a>
          <% end %>
          <button phx-click="remove" class="btn btn-red" data-confirm="Permanently remove this mission and all its data? This cannot be undone.">Remove</button>
          <a href="/dashboard/missions" class="btn btn-grey">Back</a>
        </div>
      </div>

      <%!-- Phase Stepper --%>
      <div class="panel">
        <div class="panel-title">Phase Pipeline</div>
        <div class="stepper">
          <%= for {phase, idx} <- Enum.with_index(@phases) do %>
            <%= if idx > 0 do %>
              <% prev = Enum.at(@phases, idx - 1) %>
              <div class={"step-line #{cond do
                phase_skipped?(@mission, prev) and phase_skipped?(@mission, phase) -> "step-line-skipped"
                phase_done?(@mission, prev) and not phase_skipped?(@mission, phase) -> "step-line-done"
                true -> ""
              end}"}></div>
            <% end %>
            <div
              class={"step #{phase_step_class(@mission, phase)}"}
              phx-click="select_phase"
              phx-value-phase={phase}
            >
              <div class="step-circle">
                <%= cond do %>
                  <% phase_skipped?(@mission, phase) -> %>
                    <span style="color:#4b5563">—</span>
                  <% phase_done?(@mission, phase) -> %>
                    <Heroicons.check mini class="w-4 h-4" />
                  <% true -> %>
                    <.phase_icon phase={phase} />
                <% end %>
              </div>
              <div class="step-label">{phase}</div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Phase Artifact Viewer --%>
      <%= if @selected_phase do %>
        <div class="panel">
          <div class="panel-title">Phase: {@selected_phase}</div>
          <%= if @artifact do %>
            <div class="pre-block">{inspect(@artifact, pretty: true, limit: :infinity)}</div>
          <% else %>
            <div class="empty">No artifact stored for this phase.</div>
          <% end %>
        </div>
      <% end %>

      <%!-- Report --%>
      <%= if @report do %>
        <div class="panel">
          <div class="panel-title">Report</div>
          <div class="pre-block">{@report}</div>
        </div>
      <% end %>

      <%!-- Ops Table --%>
      <div class="panel">
        <div class="panel-title">Ops ({length(@ops)})</div>
        <%= if @ops == [] do %>
          <div class="empty">No ops created yet.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th>ID</th>
                <th>Title</th>
                <th>Status</th>
                <th>Audit</th>
                <th>Ghost</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for op <- @ops do %>
                <tr class="detail-toggle" phx-click="toggle_op" phx-value-id={op.id}>
                  <td style="width:1.5rem">{if MapSet.member?(@expanded_ops, op.id), do: "v", else: ">"}</td>
                  <td>
                    <a href={"/dashboard/ops/#{op.id}"} style="font-family:monospace; font-size:0.8rem">
                      {short_id(op.id)}
                    </a>
                  </td>
                  <td>{Map.get(op, :title, "-")}</td>
                  <td><span class={"badge #{status_badge(Map.get(op, :status, "unknown"))}"}>{Map.get(op, :status, "unknown")}</span></td>
                  <td>
                    <%= if Map.get(op, :verification_status) do %>
                      <span class={"badge #{verification_badge(op.verification_status)}"}>{op.verification_status}</span>
                    <% else %>
                      <span class="badge badge-grey">-</span>
                    <% end %>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem">{short_id(Map.get(op, :ghost_id))}</td>
                  <td>
                    <%= if Map.get(op, :status) == "failed" do %>
                      <button phx-click="reset_op" phx-value-id={op.id} class="btn btn-grey" style="padding:0.2rem 0.5rem; font-size:0.75rem">
                        Reset
                      </button>
                    <% end %>
                  </td>
                </tr>
                <%= if MapSet.member?(@expanded_ops, op.id) do %>
                  <tr>
                    <td colspan="7" style="padding:0">
                      <div class="detail-content">
                        <dl class="metadata-grid">
                          <dt>Type</dt><dd>{Map.get(op, :type, "-")}</dd>
                          <dt>Complexity</dt><dd>{Map.get(op, :complexity, "-")}</dd>
                          <dt>Risk</dt><dd>{Map.get(op, :risk_level, "-")}</dd>
                          <dt>Retries</dt><dd>{Map.get(op, :retry_count, 0)}</dd>
                        </dl>
                        <%= if Map.get(op, :description) do %>
                          <div style="margin-top:0.75rem; color:#8b949e; font-size:0.85rem">{op.description}</div>
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

  # Map orchestrator phases that aren't in the visual pipeline to their
  # nearest visual equivalent.  "awaiting_approval" sits between validation
  # and sync, so we display it as if the mission is at the "sync" step.
  defp phase_icon(%{phase: "pending"} = assigns), do: ~H"<Heroicons.clock mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "research"} = assigns), do: ~H"<Heroicons.magnifying_glass mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "requirements"} = assigns), do: ~H"<Heroicons.clipboard_document_list mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "design"} = assigns), do: ~H"<Heroicons.cube_transparent mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "review"} = assigns), do: ~H"<Heroicons.eye mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "planning"} = assigns), do: ~H"<Heroicons.map mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "implementation"} = assigns), do: ~H"<Heroicons.wrench_screwdriver mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "validation"} = assigns), do: ~H"<Heroicons.shield_check mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "sync"} = assigns), do: ~H"<Heroicons.arrow_path_rounded_square mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "simplify"} = assigns), do: ~H"<Heroicons.sparkles mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "scoring"} = assigns), do: ~H"<Heroicons.chart_bar mini class='w-4 h-4' />"
  defp phase_icon(%{phase: "completed"} = assigns), do: ~H"<Heroicons.flag mini class='w-4 h-4' />"
  defp phase_icon(assigns), do: ~H"<span>{@phase |> String.first() |> String.upcase()}</span>"

  defp normalise_phase("awaiting_approval"), do: "sync"
  defp normalise_phase(phase), do: phase

  # Phases that fast-path missions actually execute
  @fast_phases ~w(pending implementation validation sync scoring completed)

  defp phase_done?(mission, phase) do
    current = normalise_phase(Map.get(mission, :current_phase, "pending"))
    current_idx = Enum.find_index(@phases, &(&1 == current)) || 0
    phase_idx = Enum.find_index(@phases, &(&1 == phase)) || 0
    phase_idx < current_idx
  end

  defp phase_skipped?(mission, phase) do
    Map.get(mission, :pipeline_mode) == "fast" and phase not in @fast_phases
  end

  defp phase_step_class(mission, phase) do
    current = normalise_phase(Map.get(mission, :current_phase, "pending"))

    cond do
      phase == current -> "step-active"
      phase_skipped?(mission, phase) -> "step-skipped"
      phase_done?(mission, phase) -> "step-done"
      true -> "step-future"
    end
  end
end
