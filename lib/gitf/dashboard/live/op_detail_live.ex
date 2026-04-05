defmodule GiTF.Dashboard.OpDetailLive do
  @moduledoc "Op detail page showing full op metadata, acceptance criteria, and verification."

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    case GiTF.Ops.get(id) do
      {:ok, op} ->
        {:ok,
         socket
         |> assign(:page_title, Map.get(op, :title, "Op"))
         |> assign(:current_path, "/dashboard/missions")
         |> assign(:op, op)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Op not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, reload(socket)}
  end

  def handle_info({:waggle_received, _}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset", _params, socket) do
    case GiTF.Ops.reset(socket.assigns.op.id, nil) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Op reset.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  def handle_event("kill", _params, socket) do
    case GiTF.Ops.kill(socket.assigns.op.id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Op killed.") |> reload()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Kill failed: #{inspect(reason)}")}
    end
  end

  defp reload(socket) do
    case GiTF.Ops.get(socket.assigns.op.id) do
      {:ok, op} -> assign(socket, :op, op)
      {:error, _} -> socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <%!-- Header --%>
      <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:1.25rem; flex-wrap:wrap; gap:0.75rem">
        <div>
          <h1 class="page-title" style="margin-bottom:0.25rem">{Map.get(@op, :title, "Op")}</h1>
          <div style="display:flex; gap:0.5rem; align-items:center">
            <span class={"badge #{status_badge(Map.get(@op, :status, "unknown"))}"}>{Map.get(@op, :status, "unknown")}</span>
            <%= if Map.get(@op, :verification_status) do %>
              <span class={"badge #{verification_badge(@op.verification_status)}"}>{@op.verification_status}</span>
            <% end %>
            <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">{@op.id}</span>
          </div>
        </div>
        <div style="display:flex; gap:0.5rem">
          <%= if Map.get(@op, :status) == "failed" do %>
            <button phx-click="reset" class="btn btn-blue">Reset</button>
          <% end %>
          <%= if Map.get(@op, :status) in ["active", "running", "assigned"] do %>
            <button phx-click="kill" class="btn btn-red" data-confirm="Kill this op?">Kill</button>
          <% end %>
          <%= if Map.get(@op, :mission_id) do %>
            <a href={"/dashboard/missions/#{@op.mission_id}"} class="btn btn-grey">Back to Mission</a>
          <% else %>
            <a href="/dashboard/missions" class="btn btn-grey">Back</a>
          <% end %>
        </div>
      </div>

      <%!-- Metadata --%>
      <div class="panel">
        <div class="panel-title">Metadata</div>
        <div class="grid-2">
          <dl class="metadata-grid">
            <dt>Type</dt><dd>{Map.get(@op, :type, "-")}</dd>
            <dt>Complexity</dt><dd>{Map.get(@op, :complexity, "-")}</dd>
            <dt>Model</dt><dd>{Map.get(@op, :model, "-")}</dd>
            <dt>Risk</dt><dd>{Map.get(@op, :risk_level, "-")}</dd>
          </dl>
          <dl class="metadata-grid">
            <dt>Retries</dt><dd>{Map.get(@op, :retry_count, 0)}</dd>
            <dt>Ghost</dt>
            <dd>
              <%= if Map.get(@op, :ghost_id) do %>
                <span style="font-family:monospace">{short_id(@op.ghost_id)}</span>
              <% else %>
                -
              <% end %>
            </dd>
            <dt>Mission</dt>
            <dd>
              <%= if Map.get(@op, :mission_id) do %>
                <a href={"/dashboard/missions/#{@op.mission_id}"} style="font-family:monospace">{short_id(@op.mission_id)}</a>
              <% else %>
                -
              <% end %>
            </dd>
            <dt>Phase</dt><dd>{Map.get(@op, :phase, "-")}</dd>
          </dl>
        </div>
      </div>

      <%!-- Description --%>
      <%= if Map.get(@op, :description) do %>
        <div class="panel">
          <div class="panel-title">Description</div>
          <div style="color:#c9d1d9; font-size:0.9rem; line-height:1.6">{@op.description}</div>
        </div>
      <% end %>

      <%!-- Acceptance Criteria --%>
      <%= if Map.get(@op, :acceptance_criteria) do %>
        <div class="panel">
          <div class="panel-title">Acceptance Criteria</div>
          <%= if is_list(@op.acceptance_criteria) do %>
            <%= for criterion <- @op.acceptance_criteria do %>
              <div style="padding:0.35rem 0; display:flex; gap:0.5rem; align-items:flex-start">
                <span style={"color:#{if Map.get(@op, :verification_status) == "passed", do: "#3fb950", else: "#8b949e"}"}>
                  {if Map.get(@op, :verification_status) == "passed", do: "✓", else: "○"}
                </span>
                <span style="font-size:0.9rem">{criterion}</span>
              </div>
            <% end %>
          <% else %>
            <div style="color:#c9d1d9; font-size:0.9rem">{@op.acceptance_criteria}</div>
          <% end %>
        </div>
      <% end %>

      <%!-- Verification --%>
      <%= if Map.get(@op, :verification_result) do %>
        <div class="panel">
          <div class="panel-title">Verification Result</div>
          <div class="pre-block">{inspect(@op.verification_result, pretty: true, limit: :infinity)}</div>
        </div>
      <% end %>

      <%!-- Target Files --%>
      <%= if Map.get(@op, :target_files) && @op.target_files != [] do %>
        <div class="panel">
          <div class="panel-title">Target Files</div>
          <%= for file <- List.wrap(@op.target_files) do %>
            <div style="padding:0.25rem 0; font-family:monospace; font-size:0.85rem; color:#58a6ff">{file}</div>
          <% end %>
        </div>
      <% end %>

      <%!-- Audit --%>
      <%= if Map.get(@op, :audit_result) do %>
        <div class="panel">
          <div class="panel-title">Audit Result</div>
          <div class="pre-block">{inspect(@op.audit_result, pretty: true, limit: :infinity)}</div>
        </div>
      <% end %>
    </.live_component>
    """
  end
end
