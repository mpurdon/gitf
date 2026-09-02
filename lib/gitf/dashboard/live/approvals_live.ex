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
     |> assign(:action_mission_id, nil)
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

  # TWO ids, deliberately. `action_id` is the :approval_requests record id
  # (`apr-…`) and exists only to decide WHICH card expands its modal.
  # `action_mission_id` is what `GiTF.Override` actually operates on.
  #
  # They were one assign until 2026-08-30, and it was the request id — so
  # `Override.approve/2` was handed `apr-034baf` where it wanted `msn-…`,
  # `Missions.store_artifact/3` answered `{:error, :not_found}`, and the
  # operator got a flash they could miss. The Catwalk's approve and reject
  # buttons had therefore NEVER worked, on either path, for as long as this
  # page has existed. Keep the two apart: collapsing them back would fix
  # the write and silently break modal targeting the moment two requests
  # are pending at once.
  @impl true
  def handle_event("show_approve", %{"id" => id} = params, socket) do
    {:noreply, start_action(socket, id, params["mission"], :approve)}
  end

  def handle_event("show_reject", %{"id" => id} = params, socket) do
    {:noreply, start_action(socket, id, params["mission"], :reject)}
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, clear_action(socket)}
  end

  def handle_event("update_notes", %{"notes" => text}, socket) do
    {:noreply, assign(socket, :notes, text)}
  end

  def handle_event("confirm_approve", _params, socket) do
    with_mission(socket, fn mission_id ->
      actor = GiTF.Web.TailnetAuth.actor(socket.assigns)

      case GiTF.Override.approve(mission_id, %{
             approved_by: actor,
             notes: socket.assigns.notes
           }) do
        {:ok, _} ->
          GiTF.AuditLog.record(actor, "approval.approve", mission_id, %{
            notes: socket.assigns.notes
          })

          {:noreply,
           socket
           |> clear_action()
           |> assign(:approvals, load_approvals())
           |> put_flash(:info, "Approved.")}

        {:error, reason} ->
          # Leave the modal OPEN: the message has to land next to the
          # button they pressed, not above a card they have scrolled past.
          {:noreply, put_flash(socket, :error, action_error("Approve", mission_id, reason))}
      end
    end)
  end

  def handle_event("confirm_reject", _params, socket) do
    reason = String.trim(socket.assigns.notes)

    if reason == "" do
      {:noreply, put_flash(socket, :error, "Rejection reason is required.")}
    else
      with_mission(socket, fn mission_id ->
        actor = GiTF.Web.TailnetAuth.actor(socket.assigns)

        case GiTF.Override.reject(mission_id, reason, %{rejected_by: actor}) do
          {:ok, _} ->
            GiTF.AuditLog.record(actor, "approval.reject", mission_id, %{reason: reason})

            {:noreply,
             socket
             |> clear_action()
             |> assign(:approvals, load_approvals())
             |> put_flash(:info, "Rejected.")}

          {:error, err} ->
            {:noreply, put_flash(socket, :error, action_error("Reject", mission_id, err))}
        end
      end)
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :approvals, load_approvals())}
  end

  defp start_action(socket, request_id, mission_id, type) do
    assign(socket,
      action_id: request_id,
      action_mission_id: mission_id,
      action_type: type,
      notes: ""
    )
  end

  defp clear_action(socket) do
    assign(socket, action_id: nil, action_mission_id: nil, action_type: nil, notes: "")
  end

  # A request whose mission is gone must not silently no-op — that is the
  # whole failure mode this page just had.
  defp with_mission(socket, fun) do
    case socket.assigns.action_mission_id do
      mission_id when is_binary(mission_id) and mission_id != "" ->
        fun.(mission_id)

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Approval request #{socket.assigns.action_id || "(unknown)"} carries no mission id, " <>
             "so there is nothing to decide. The request is stale — delete it, or find the " <>
             "mission and act on it there."
         )}
    end
  end

  defp action_error(verb, mission_id, reason) do
    "#{verb} failed for mission #{mission_id}: #{inspect(reason)}. " <>
      "The approval request may be stale (its mission deleted or already decided) — " <>
      "check the mission before retrying."
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
                  <span style="font-weight:600; color:var(--text)">
                    {mission_title(approval)}
                  </span>
                  <a
                    :if={approval[:mission_id]}
                    href={"/dashboard/missions/#{approval.mission_id}"}
                    style="font-family:monospace; font-size:0.75rem; color:var(--accent); text-decoration:none"
                  >{approval.mission_id}</a>
                </div>
                <div style="font-size:0.78rem; color:var(--muted); margin-bottom:0.6rem">
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
                    style="font-size:0.75rem; color:var(--accent)"
                  >plan</a>
                </div>
              </div>
              <div style="display:flex; flex-direction:column; align-items:flex-end; gap:0.4rem">
                <div style="display:flex; gap:0.5rem">
                  <%= if @action_id == Map.get(approval, :id) do %>
                    <%!-- action form shown inline --%>
                  <% else %>
                    <%!-- id targets the modal, mission is what gets decided.
                          They are different records; conflating them is the
                          bug that made these buttons do nothing. --%>
                    <button
                      phx-click="show_approve"
                      phx-value-id={approval.id}
                      phx-value-mission={approval[:mission_id]}
                      class="btn btn-green"
                    >Approve</button>
                    <button
                      phx-click="show_reject"
                      phx-value-id={approval.id}
                      phx-value-mission={approval[:mission_id]}
                      class="btn btn-red"
                    >Reject</button>
                  <% end %>
                </div>
                <div :if={triage = Map.get(approval, :triage)} class="triage-tally">
                  {GiTF.Approval.Triage.tally(triage)}
                </div>
                <%!-- An omission is a fail, but it should be visible before
                      the operator reads a single item. --%>
                <div :if={triage = Map.get(approval, :triage)} class="triage-coverage">
                  {GiTF.Approval.Triage.coverage_line(triage)}
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
            <div :if={Map.get(approval, :validation_summary)} style="margin-top:0.9rem; font-size:0.85rem; color:var(--text-2); white-space:pre-wrap">
              {approval.validation_summary}
            </div>

            <details :if={goal_text(approval) != ""} style="margin-top:0.6rem">
              <summary style="cursor:pointer; font-size:0.78rem; color:var(--muted)">
                {String.slice(goal_text(approval), 0, 140)}…
              </summary>
              <div style="color:var(--muted); font-size:0.85rem; margin-top:0.5rem; white-space:pre-wrap">{goal_text(approval)}</div>
            </details>

            <%= if @action_id == Map.get(approval, :id) do %>
              <div style="margin-top:1rem; padding-top:1rem; border-top:1px solid var(--line)">
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
        <%!-- The id and its verdict are the label; the requirement is the
              line you actually read. "FR-1 met" is a citation, not
              information. --%>
        <div class="triage-item-label">
          {@item.title}
          <span :if={@item.priority} class="badge badge-grey triage-priority">{@item.priority}</span>
          <span class="triage-item-kind">{@item.kind}</span>
        </div>
        <div :if={@item.requirement} class="triage-requirement">{@item.requirement}</div>
        <details :if={expandable?(@item)}>
          <summary style="cursor:pointer; font-size:0.75rem; color:var(--muted)">detail</summary>
          <div class="triage-detail">{@item.detail}</div>
        </details>
        <details :if={@item.acceptance_criteria != []}>
          <summary style="cursor:pointer; font-size:0.75rem; color:var(--muted)">
            {length(@item.acceptance_criteria)} acceptance criteria
          </summary>
          <ul class="triage-criteria">
            <li :for={criterion <- @item.acceptance_criteria}>{criterion}</li>
          </ul>
        </details>
        <details :if={@item.rebuttal}>
          <summary style="cursor:pointer; font-size:0.75rem; color:var(--ok)">rebuttal</summary>
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
