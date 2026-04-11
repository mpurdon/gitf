defmodule GiTF.Dashboard.ApprovalsLive do
  @moduledoc "Approval queue for mission/op approval requests."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(5)
  # Placeholder until dashboard auth provides real user identity
  @default_user "dashboard_user"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:alerts")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(:page_title, "Approvals")
     |> assign(:current_path, "/approvals")
     |> assign(:approvals, load_approvals())
     |> assign(:action_id, nil)
     |> assign(:action_type, nil)
     |> assign(:notes, "")
     |> init_toasts()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, :approvals, load_approvals())}
  end

  def handle_info({:waggle_received, waggle}, socket) do
    {:noreply, socket |> maybe_apply_toast(waggle) |> assign(:approvals, load_approvals())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
    case GiTF.Override.approve(socket.assigns.action_id, %{
           approved_by: @default_user,
           notes: socket.assigns.notes
         }) do
      {:ok, _} ->
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
      case GiTF.Override.reject(socket.assigns.action_id, reason, %{
             rejected_by: @default_user
           }) do
        {:ok, _} ->
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

  defp load_approvals do
    try do
      GiTF.Override.pending_approvals()
    rescue
      _ -> []
    end
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
            <div style="display:flex; justify-content:space-between; align-items:flex-start">
              <div>
                <div style="font-weight:600; color:#f0f6fc; margin-bottom:0.35rem">
                  {Map.get(approval, :mission_name, Map.get(approval, :name, "Approval Request"))}
                </div>
                <div style="color:#8b949e; font-size:0.85rem; margin-bottom:0.5rem">
                  {Map.get(approval, :goal, Map.get(approval, :description, ""))}
                </div>
                <div style="display:flex; gap:0.5rem; flex-wrap:wrap; align-items:center">
                  <%= if Map.get(approval, :risk_level) do %>
                    <span class={"badge #{risk_badge(approval.risk_level)}"}>{approval.risk_level} risk</span>
                  <% end %>
                  <%= if Map.get(approval, :op_count) do %>
                    <span class="badge badge-grey">{approval.op_count} ops</span>
                  <% end %>
                  <%= if Map.get(approval, :file_count) do %>
                    <span class="badge badge-grey">{approval.file_count} files</span>
                  <% end %>
                  <span style="font-size:0.8rem; color:#8b949e">
                    {format_timestamp(Map.get(approval, :requested_at, Map.get(approval, :inserted_at)))}
                  </span>
                </div>
              </div>
              <div style="display:flex; gap:0.5rem">
                <%= if @action_id == Map.get(approval, :id) do %>
                  <%!-- action form shown inline --%>
                <% else %>
                  <button phx-click="show_approve" phx-value-id={approval.id} class="btn btn-green">Approve</button>
                  <button phx-click="show_reject" phx-value-id={approval.id} class="btn btn-red">Reject</button>
                <% end %>
              </div>
            </div>

            <%= if @action_id == Map.get(approval, :id) do %>
              <div style="margin-top:1rem; padding-top:1rem; border-top:1px solid #30363d">
                <%= if @action_type == :approve do %>
                  <div class="form-group">
                    <label class="form-label">Notes (optional)</label>
                    <textarea class="form-textarea" name="notes" phx-change="update_notes" style="min-height:60px">{@notes}</textarea>
                  </div>
                  <div class="action-bar">
                    <button phx-click="cancel_action" class="btn btn-grey">Cancel</button>
                    <button phx-click="confirm_approve" class="btn btn-green">Confirm Approve</button>
                  </div>
                <% else %>
                  <div class="form-group">
                    <label class="form-label">Reason (required)</label>
                    <textarea class="form-textarea" name="notes" phx-change="update_notes" style="min-height:60px" required>{@notes}</textarea>
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

  defp risk_badge("high"), do: "badge-red"
  defp risk_badge("medium"), do: "badge-yellow"
  defp risk_badge("low"), do: "badge-green"
  defp risk_badge(_), do: "badge-grey"
end
