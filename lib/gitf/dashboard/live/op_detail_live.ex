defmodule GiTF.Dashboard.OpDetailLive do
  @moduledoc "Op detail page showing full op metadata, acceptance criteria, and verification."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    case GiTF.Ops.get(id) do
      {:ok, op} ->
        {:ok,
         socket
         |> assign(:page_title, Map.get(op, :title, "Op"))
         |> assign(:current_path, "/dashboard/missions")
         |> assign(:op, op)
         |> assign_extras(op)
         |> assign_siblings(op)
         |> init_toasts()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Op not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, reload(socket)}
  end

  def handle_info({:waggle_received, waggle}, socket),
    do: {:noreply, socket |> maybe_apply_toast(waggle) |> reload()}

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
      {:ok, op} -> socket |> assign(:op, op) |> assign_extras(op) |> assign_siblings(op)
      {:error, _} -> socket
    end
  end

  defp assign_siblings(socket, op) do
    all_ops =
      GiTF.Archive.all(:ops)
      |> Enum.sort_by(& &1[:inserted_at], {:asc, DateTime})

    idx = Enum.find_index(all_ops, &(&1.id == op.id))

    prev_op = if idx && idx > 0, do: Enum.at(all_ops, idx - 1)
    next_op = if idx, do: Enum.at(all_ops, idx + 1)

    socket
    |> assign(:prev_op, prev_op)
    |> assign(:next_op, next_op)
  end

  defp assign_extras(socket, op) do
    # Retry chain: walk retry_of → parent, retried_as → children
    retry_chain = build_retry_chain(op)

    # Ghost info
    ghost =
      case op[:ghost_id] do
        nil -> nil
        gid -> GiTF.Archive.get(:ghosts, gid)
      end

    # Shell info
    shell =
      case ghost do
        nil ->
          nil

        g ->
          GiTF.Archive.find_one(:shells, fn s ->
            s[:ghost_id] == g.id and s.status == "active"
          end)
      end

    mission =
      case op[:mission_id] do
        nil -> nil
        mid -> GiTF.Archive.get(:missions, mid)
      end

    socket
    |> assign(:retry_chain, retry_chain)
    |> assign(:ghost, ghost)
    |> assign(:shell, shell)
    |> assign(:mission, mission)
  end

  defp build_retry_chain(op) do
    # Walk backwards to find root
    root = find_retry_root(op)
    # Walk forwards to build chain
    build_chain_forward(root, [])
  end

  defp find_retry_root(op) do
    case op[:retry_of] do
      nil ->
        op

      parent_id ->
        case GiTF.Archive.get(:ops, parent_id) do
          nil -> op
          parent -> find_retry_root(parent)
        end
    end
  rescue
    _ -> op
  end

  defp build_chain_forward(op, acc) do
    entry = %{
      id: op.id,
      status: op.status,
      title: op[:title],
      retry_strategy: op[:retry_strategy],
      retry_count: op[:retry_count] || 0
    }

    acc = [entry | acc]

    case op[:retried_as] do
      nil ->
        Enum.reverse(acc)

      next_id ->
        case GiTF.Archive.get(:ops, next_id) do
          nil -> Enum.reverse(acc)
          next -> build_chain_forward(next, acc)
        end
    end
  rescue
    _ -> Enum.reverse(acc)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <.breadcrumbs crumbs={[
        {"Missions", "/dashboard/missions"},
        {(@mission && Map.get(@mission, :name)) || "Mission", @op[:mission_id] && "/dashboard/missions/#{@op.mission_id}"},
        {Map.get(@op, :title, "Op"), nil}
      ]} />
      <%!-- Header --%>
      <div style="margin-bottom:1.25rem">
        <div style="display:flex; gap:0.5rem; align-items:center; margin-bottom:0.5rem; flex-wrap:wrap">
          <span class={"badge #{status_badge(Map.get(@op, :status, "unknown"))}"}>{Map.get(@op, :status, "unknown")}</span>
          <%= if Map.get(@op, :verification_status) do %>
            <span class={"badge #{verification_badge(@op.verification_status)}"}>{@op.verification_status}</span>
          <% end %>
          <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">{@op.id}</span>
        </div>
        <h1 class="page-title" style="margin-bottom:0.75rem; font-size:1.1rem; line-height:1.4; word-break:break-word">
          {Map.get(@op, :title, "Op")}
        </h1>
        <div style="display:flex; gap:0.5rem; align-items:center; flex-wrap:wrap">
          <%= if @prev_op do %>
            <a href={"/dashboard/ops/#{@prev_op.id}"} class="btn btn-grey" title={Map.get(@prev_op, :title, "Previous op")}>&larr; Prev</a>
          <% end %>
          <%= if @next_op do %>
            <a href={"/dashboard/ops/#{@next_op.id}"} class="btn btn-grey" title={Map.get(@next_op, :title, "Next op")}>Next &rarr;</a>
          <% end %>
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

      <%!-- Ghost & Shell --%>
      <%= if @ghost do %>
        <div class="panel">
          <div class="panel-title">Ghost</div>
          <div class="grid-2">
            <dl class="metadata-grid">
              <dt>Ghost ID</dt><dd style="font-family:monospace">{short_id(@ghost.id)}</dd>
              <dt>Model</dt><dd>{Map.get(@ghost, :assigned_model, "-")}</dd>
              <dt>Status</dt><dd><span class={"badge #{status_badge(Map.get(@ghost, :status, "unknown"))}"}>{Map.get(@ghost, :status, "?")}</span></dd>
            </dl>
            <dl class="metadata-grid">
              <dt>Context</dt><dd>{Float.round((Map.get(@ghost, :context_percentage, 0.0) || 0.0) * 100, 1)}%</dd>
              <%= if @shell do %>
                <dt>Worktree</dt><dd style="font-size:0.75rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:200px" title={@shell[:worktree_path]}>{@shell[:worktree_path] && Path.basename(@shell.worktree_path)}</dd>
                <dt>Drift</dt><dd><span class={"badge #{case @shell[:drift_state] do
                  d when d in [:clean, "clean"] -> "badge-green"
                  d when d in [:behind, "behind"] -> "badge-yellow"
                  d when d in [:risky, "risky"] -> "badge-orange"
                  d when d in [:conflicted, "conflicted"] -> "badge-red"
                  _ -> "badge-grey"
                end}"}>{@shell[:drift_state] || "unknown"}</span></dd>
              <% end %>
            </dl>
          </div>
        </div>
      <% end %>

      <%!-- Retry Chain --%>
      <%= if length(@retry_chain) > 1 do %>
        <div class="panel">
          <div class="panel-title">Retry Chain</div>
          <div style="display:flex; align-items:center; gap:0.25rem; flex-wrap:wrap">
            <%= for {entry, idx} <- Enum.with_index(@retry_chain) do %>
              <%= if idx > 0 do %>
                <span style="color:#6b7280; font-size:0.8rem">&rarr;</span>
              <% end %>
              <a
                href={"/dashboard/ops/#{entry.id}"}
                style={"padding:0.25rem 0.5rem; border-radius:4px; font-size:0.8rem; text-decoration:none; border:1px solid #{if entry.id == @op.id, do: "#58a6ff", else: "#30363d"}; background:#{if entry.id == @op.id, do: "#1c2128", else: "transparent"}; color:#{case entry.status do
                  "done" -> "#3fb950"
                  "failed" -> "#f85149"
                  "running" -> "#58a6ff"
                  _ -> "#8b949e"
                end}"}
              >
                #{entry.retry_count}
                <span class={"badge #{status_badge(entry.status)}"} style="font-size:0.55rem; margin-left:0.25rem">{entry.status}</span>
                <%= if entry.retry_strategy do %>
                  <span style="font-size:0.6rem; color:#6b7280; margin-left:0.25rem">({entry.retry_strategy})</span>
                <% end %>
              </a>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Description --%>
      <%= if Map.get(@op, :description) do %>
        <div class="panel">
          <div class="panel-title">Description</div>
          <div style="color:#c9d1d9; font-size:0.9rem; line-height:1.6">{@op.description}</div>
        </div>
      <% end %>

      <%!-- Failure Info --%>
      <%= if @op.status == "failed" do %>
        <div class="panel" style="border-left:3px solid #f85149">
          <div class="panel-title" style="color:#f85149">Failure Details</div>
          <%= if Map.get(@op, :error_message) do %>
            <div style="margin-bottom:0.75rem">
              <div style="font-size:0.75rem; color:#6b7280; margin-bottom:0.25rem">Error Message</div>
              <div class="pre-block" style="border-color:#f8514933">{@op.error_message}</div>
            </div>
          <% end %>
          <%= if Map.get(@op, :failure_info) do %>
            <div style="margin-bottom:0.75rem">
              <div style="font-size:0.75rem; color:#6b7280; margin-bottom:0.25rem">Failure Analysis</div>
              <div class="pre-block">{inspect(@op.failure_info, pretty: true, limit: :infinity)}</div>
            </div>
          <% end %>
          <%= if Map.get(@op, :audit_result) do %>
            <div>
              <div style="font-size:0.75rem; color:#6b7280; margin-bottom:0.25rem">Audit Output</div>
              <div class="pre-block">{@op.audit_result}</div>
            </div>
          <% end %>
          <%= if is_nil(Map.get(@op, :error_message)) and is_nil(Map.get(@op, :failure_info)) and is_nil(Map.get(@op, :audit_result)) do %>
            <div style="color:#8b949e; font-size:0.85rem">No failure details recorded. Check <a href={"/dashboard/missions/#{@op.mission_id}/diagnostics"} style="color:#58a6ff">diagnostics</a> for more info.</div>
          <% end %>
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
