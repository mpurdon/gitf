defmodule GiTF.Dashboard.ApprovalsLive do
  @moduledoc "Approval queue for mission/op approval requests."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:alerts")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    # Skip approvals fetch on the disconnected HTTP render pass.
    approvals = if connected?(socket), do: load_approvals(), else: []

    {:ok,
     socket
     |> assign(:page_title, "Approvals")
     |> assign(:current_path, "/approvals")
     |> assign(:approvals, approvals)
     |> assign(:action_id, nil)
     |> assign(:action_type, nil)
     |> assign(:notes, "")
     |> assign(:refresh_scheduled, false)
     |> init_toasts()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}
  end

  # Debounced refresh: collapse rapid PubSub events into one reload 150ms out.
  def handle_info(:debounced_refresh, socket) do
    {:noreply,
     socket |> assign(:refresh_scheduled, false) |> assign(:approvals, load_approvals())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  @impl true
  def handle_event("show_approve", %{"id" => id}, socket) do
    {:noreply, assign(socket, action_id: id, action_type: :approve, notes: "")}
  end

  def handle_event("show_reject", %{"id" => id}, socket) do
    {:noreply, assign(socket, action_id: id, action_type: :reject, notes: "")}
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, assign(socket, action_id: nil, action_type: nil, notes: "")}
  end

  def handle_event("update_notes", %{"notes" => text}, socket) do
    {:noreply, assign(socket, :notes, text)}
  end

  def handle_event("confirm_approve", _params, socket) do
    actor = GiTF.Web.TailnetAuth.actor(socket.assigns)

    case GiTF.Override.approve(socket.assigns.action_id, %{
           approved_by: actor,
           notes: socket.assigns.notes
         }) do
      {:ok, _} ->
        GiTF.AuditLog.record(actor, "approval.approve", socket.assigns.action_id, %{
          notes: socket.assigns.notes
        })

        {:noreply,
         socket
         |> assign(action_id: nil, action_type: nil, notes: "")
         |> assign(:approvals, load_approvals())
         |> put_flash(:info, "Approved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm_reject", _params, socket) do
    reason = String.trim(socket.assigns.notes)

    if reason == "" do
      {:noreply, put_flash(socket, :error, "Rejection reason is required.")}
    else
      actor = GiTF.Web.TailnetAuth.actor(socket.assigns)

      case GiTF.Override.reject(socket.assigns.action_id, reason, %{
             rejected_by: actor
           }) do
        {:ok, _} ->
          GiTF.AuditLog.record(actor, "approval.reject", socket.assigns.action_id, %{
            reason: reason
          })

          {:noreply,
           socket
           |> assign(action_id: nil, action_type: nil, notes: "")
           |> assign(:approvals, load_approvals())
           |> put_flash(:info, "Rejected.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Reject failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :approvals, load_approvals())}
  end

  defp mission_title(approval) do
    approval[:mission][:name] ||
      Map.get(approval, :mission_name, Map.get(approval, :name, "Approval Request"))
  end

  defp goal_text(approval) do
    to_string(Map.get(approval, :goal, Map.get(approval, :description, "")))
  end

  # The validator's own prose. It belongs BELOW the triage groups, not
  # above them: it is discussion, and discussion is what the operator
  # reads after they know whether anything failed.
  defp validation_summary(artifact) when is_map(artifact) do
    case artifact["summary"] do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp validation_summary(_), do: nil

  defp load_approvals do
    GiTF.Override.pending_approvals() |> Enum.map(&enrich/1)
  rescue
    _ -> []
  end

  # The card's job is the DECISION, and the raw request carries only the
  # goal text — a wall of prose with two buttons. Join what the approver
  # actually weighs: which gate this is, validation's verdict and coverage,
  # what it costs, where to look deeper. All best-effort; a missing mission
  # still renders the bare request.
  #
  # The triage grouping is the headline of the card: `GiTF.Approval.Triage`
  # turns the artifact's structured fields into fails / concerns / oks so
  # the operator never has to open the JSON to learn whether gap #1 was
  # behavioral or cosmetic.
  defp enrich(approval) do
    with mission_id when is_binary(mission_id) <- approval[:mission_id],
         {:ok, mission} <- GiTF.Missions.get(mission_id) do
      validation = GiTF.Missions.get_artifact(mission_id, "validation")
      triage = GiTF.Approval.Triage.build(mission)

      impl_ops =
        mission
        |> Map.get(:ops, [])
        |> Enum.reject(&Map.get(&1, :phase_job, false))

      cost =
        GiTF.Archive.filter(:costs, &(&1[:mission_id] == mission_id))
        |> Enum.map(&(&1[:cost_usd] || 0.0))
        |> Enum.sum()

      approval
      |> Map.put(:mission, mission)
      |> Map.put(:validation, validation)
      |> Map.put(:triage, triage)
      |> Map.put(:validation_summary, validation_summary(validation))
      |> Map.put(
        :validation_chips,
        GiTF.Dashboard.MissionDetailLive.decisions("validation", validation)
      )
      |> Map.put(:files_changed, impl_ops |> Enum.map(&(&1[:files_changed] || 0)) |> Enum.sum())
      |> Map.put(:cost_usd, cost)
    else
      _ -> approval
    end
  rescue
    _ -> approval
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Approvals</h1>
        <button phx-click="refresh" class="btn btn-blue">Refresh</button>
      </div>

      <%= if @approvals == [] do %>
        <div class="panel">
          <div class="empty">No pending approvals. Approval requests appear here when missions reach the approval phase.</div>
        </div>
      <% else %>
        <%= for approval <- @approvals do %>
          <div class="panel" style="margin-bottom:1rem">
            <div style="display:flex; justify-content:space-between; align-items:flex-start; gap:1rem">
              <div style="min-width:0; flex:1">
                <div style="display:flex; align-items:baseline; gap:0.5rem; flex-wrap:wrap; margin-bottom:0.2rem">
                  <span style="font-weight:600; color:#f0f6fc">
                    {mission_title(approval)}
                  </span>
                  <a
                    :if={approval[:mission_id]}
                    href={"/dashboard/missions/#{approval.mission_id}"}
                    style="font-family:monospace; font-size:0.75rem; color:#58a6ff; text-decoration:none"
                  >{approval.mission_id}</a>
                </div>
                <div style="font-size:0.78rem; color:#8b949e; margin-bottom:0.6rem">
                  Publish approval — validation finished; approving merges and opens the PR.
                  <span :if={approval[:requested_at]}>
                    Requested {format_timestamp(approval[:requested_at])}.
                  </span>
                </div>
                <div style="display:flex; gap:0.4rem; flex-wrap:wrap; align-items:center; margin-bottom:0.6rem">
                  <span
                    :for={{label, value, tone} <- Map.get(approval, :validation_chips, [])}
                    class={"badge badge-#{tone}"}
                    style="font-size:0.7rem"
                  >{label}: <b>{value}</b></span>
                  <span :if={Map.get(approval, :risk_level)} class={"badge #{risk_badge(approval.risk_level)}"}>{approval.risk_level} risk</span>
                  <span :if={is_number(approval[:files_changed]) and approval.files_changed > 0} class="badge badge-grey">{approval.files_changed} files</span>
                  <span :if={is_number(approval[:cost_usd]) and approval.cost_usd > 0} class="badge badge-grey">${:erlang.float_to_binary(approval.cost_usd / 1, decimals: 2)}</span>
                  <a
                    :if={approval[:mission_id]}
                    href={"/dashboard/missions/#{approval.mission_id}/plan"}
                    style="font-size:0.75rem; color:#58a6ff"
                  >plan</a>
                </div>
              </div>
              <div style="display:flex; flex-direction:column; align-items:flex-end; gap:0.4rem">
                <div style="display:flex; gap:0.5rem">
                  <%= if @action_id == Map.get(approval, :id) do %>
                    <%!-- action form shown inline --%>
                  <% else %>
                    <button phx-click="show_approve" phx-value-id={approval.id} class="btn btn-green">Approve</button>
                    <button phx-click="show_reject" phx-value-id={approval.id} class="btn btn-red">Reject</button>
                  <% end %>
                </div>
                <div :if={triage = Map.get(approval, :triage)} class="triage-tally">
                  {GiTF.Approval.Triage.tally(triage)}
                </div>
              </div>
            </div>

            <%!-- Triage: what failed, what should worry you, what is fine --%>
            <%= if triage = Map.get(approval, :triage) do %>
              <div style="margin-top:0.9rem">
                <div :if={triage.fails != []} class="triage-warn">
                  <strong>{length(triage.fails)} {if length(triage.fails) == 1, do: "check", else: "checks"} FAILED.</strong>
                  Approving merges work the factory judged incomplete. You outrank the machine — just do it knowing.
                </div>

                <.triage_group :if={triage.fails != []} tone="fail" label={"Failures (#{length(triage.fails)})"} items={triage.fails} />
                <.triage_group :if={triage.concerns != []} tone="concerns" label={"Concerns (#{length(triage.concerns)})"} items={triage.concerns} />

                <details :if={triage.oks != []} class="triage-group triage-ok">
                  <summary class="triage-group-title" style="cursor:pointer">
                    {length(triage.oks)} ok
                  </summary>
                  <div class="triage-items">
                    <.triage_item :for={item <- triage.oks} item={item} />
                  </div>
                </details>
              </div>
            <% end %>

            <%!-- Discussion: the validator's prose and the mission goal --%>
            <div :if={Map.get(approval, :validation_summary)} style="margin-top:0.9rem; font-size:0.85rem; color:#c9d1d9; white-space:pre-wrap">
              {approval.validation_summary}
            </div>

            <details :if={goal_text(approval) != ""} style="margin-top:0.6rem">
              <summary style="cursor:pointer; font-size:0.78rem; color:#8b949e">
                {String.slice(goal_text(approval), 0, 140)}…
              </summary>
              <div style="color:#8b949e; font-size:0.85rem; margin-top:0.5rem; white-space:pre-wrap">{goal_text(approval)}</div>
            </details>

            <%= if @action_id == Map.get(approval, :id) do %>
              <div style="margin-top:1rem; padding-top:1rem; border-top:1px solid #30363d">
                <%= if @action_type == :approve do %>
                  <div
                    :if={Map.get(approval, :triage, %{fails: []}).fails != []}
                    class="triage-warn"
                  >
                    Approving over {length(approval.triage.fails)} failing {if length(approval.triage.fails) == 1, do: "check", else: "checks"}.
                  </div>
                  <div class="form-group">
                    <label class="form-label">Notes (optional)</label>
                    <textarea id="approve-notes" class="form-textarea" name="notes" phx-change="update_notes" phx-debounce="300" style="min-height:60px"><%= @notes %></textarea>
                  </div>
                  <div class="action-bar">
                    <button phx-click="cancel_action" class="btn btn-grey">Cancel</button>
                    <button phx-click="confirm_approve" class="btn btn-green">Confirm Approve</button>
                  </div>
                <% else %>
                  <div class="form-group">
                    <label class="form-label">Reason (required)</label>
                    <textarea id="reject-notes" class="form-textarea" name="notes" phx-change="update_notes" phx-debounce="300" style="min-height:60px" required><%= @notes %></textarea>
                  </div>
                  <div class="action-bar">
                    <button phx-click="cancel_action" class="btn btn-grey">Cancel</button>
                    <button phx-click="confirm_reject" class="btn btn-red">Confirm Reject</button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </.live_component>
    """
  end

  # -- Triage components -----------------------------------------------------

  attr(:tone, :string, required: true)
  attr(:label, :string, required: true)
  attr(:items, :list, required: true)

  defp triage_group(assigns) do
    ~H"""
    <div class={"triage-group triage-#{@tone}"}>
      <div class="triage-group-title">{@label}</div>
      <div class="triage-items">
        <.triage_item :for={item <- @items} item={item} />
      </div>
    </div>
    """
  end

  attr(:item, :map, required: true)

  defp triage_item(assigns) do
    ~H"""
    <div class="triage-item">
      <span class={"badge #{status_chip(@item.status)}"}>{@item.status}</span>
      <div class="triage-item-body">
        <div class="triage-item-title">
          {@item.title}<span class="triage-item-kind">{@item.kind}</span>
        </div>
        <details :if={expandable?(@item)}>
          <summary style="cursor:pointer; font-size:0.75rem; color:#8b949e">detail</summary>
          <div class="triage-detail">{@item.detail}</div>
        </details>
        <details :if={@item.rebuttal}>
          <summary style="cursor:pointer; font-size:0.75rem; color:#3fb950">rebuttal</summary>
          <div class="triage-rebuttal">{@item.rebuttal}</div>
        </details>
      </div>
    </div>
    """
  end

  # A gap's title is its own first line, so a one-line gap has nothing
  # left to expand.
  defp expandable?(%{detail: nil}), do: false

  defp expandable?(%{detail: detail, title: title}),
    do: String.trim(detail) != String.trim(title)

  defp status_chip(:fail), do: "badge-red"
  defp status_chip(:concerns), do: "badge-orange"
  defp status_chip(:ok), do: "badge-green"

  defp risk_badge("high"), do: "badge-red"
  defp risk_badge("medium"), do: "badge-yellow"
  defp risk_badge("low"), do: "badge-green"
  defp risk_badge(_), do: "badge-grey"
end
