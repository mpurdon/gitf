defmodule GiTF.Dashboard.QuestionsLive do
  @moduledoc """
  The queue of missions holding for an operator answer.

  Sibling of `ApprovalsLive` and built the same way, with one difference
  that matters: an approval is the last thing that happens to a mission,
  so its queue can afford to be a place you visit at the end. A question
  is raised MID-run and the mission does not move until it is answered,
  so this queue is a place you visit because something is stopped.

  Oldest first, deliberately — the question that has been holding a
  mission longest is the one costing the most wall clock. It is not
  sorted by mission, or by phase, or by anything that would let a fresh
  question jump ahead of one that has been waiting since last night.

  The card comes from `GiTF.Dashboard.InquiryCard`, shared with the
  mission detail page, so the same question cannot read differently
  depending on where the operator found it.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.InquiryCard

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:alerts")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    # Skip the fetch on the disconnected HTTP render pass.
    open = if connected?(socket), do: load_open(), else: []

    {:ok,
     socket
     |> assign(:page_title, "Questions")
     |> assign(:current_path, "/questions")
     |> assign(:open, open)
     |> assign(:draft, %{})
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

  def handle_info({:input_requested, _mission_id, _inquiry_id}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  # Debounced refresh: collapse rapid PubSub events into one reload 150ms out.
  def handle_info(:debounced_refresh, socket) do
    {:noreply, socket |> assign(:refresh_scheduled, false) |> assign(:open, load_open())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :open, load_open())}
  end

  def handle_event("draft_answer", %{"id" => id, "value" => value}, socket) do
    {:noreply, assign(socket, :draft, Map.put(socket.assigns.draft, id, value))}
  end

  def handle_event("answer_inquiry", %{"id" => id} = params, socket) do
    answer = params["value"] || socket.assigns.draft[id]
    actor = GiTF.Web.TailnetAuth.actor(socket.assigns)

    case GiTF.Inquiry.answer(id, answer, answered_by: actor) do
      {:ok, inquiry, :answered} ->
        GiTF.AuditLog.record(actor, "inquiry.answer", inquiry.mission_id, %{
          inquiry_id: id,
          key: inquiry[:key],
          answer: inquiry[:answer]
        })

        {:noreply,
         socket
         |> assign(:open, load_open())
         |> put_flash(
           :info,
           "Answered. #{inquiry.mission_id} resumes #{inquiry[:phase]} on the next sweep."
         )}

      {:ok, inquiry, :already_answered} ->
        # Two operators, one question, same second. The first answer wins
        # because work has already been re-dispatched against it; showing
        # the standing decision beats an opaque failure.
        {:noreply,
         socket
         |> assign(:open, load_open())
         |> put_flash(
           :info,
           "Already answered (#{inquiry[:answer_label] || inquiry[:answer]}) by " <>
             "#{inquiry[:answered_by]}. The first answer stands."
         )}

      {:error, {:invalid, reason}} ->
        {:noreply, put_flash(socket, :error, "Cannot record that answer: #{reason}")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:open, load_open())
         |> put_flash(
           :error,
           "Question #{id} no longer exists — its mission was probably deleted."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Answer failed: #{inspect(reason)}")}
    end
  end

  defp load_open do
    GiTF.Inquiry.list_open() |> Enum.map(&enrich/1)
  rescue
    _ -> []
  end

  # The card shows what is being decided; the row around it has to show
  # what is being BLOCKED. A question with no mission goal next to it is a
  # decision the operator has to go and look up before they can make it.
  defp enrich(inquiry) do
    case GiTF.Missions.get(inquiry[:mission_id]) do
      {:ok, mission} -> Map.put(inquiry, :mission_goal, mission[:goal])
      _ -> inquiry
    end
  rescue
    _ -> inquiry
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Questions</h1>
        <button phx-click="refresh" class="btn btn-blue">Refresh</button>
      </div>

      <%= if @open == [] do %>
        <div class="panel">
          <div class="empty">
            No missions are waiting on you. A phase that hits a decision only you can make
            raises a question here and the mission holds until it is answered — it never
            auto-answers, so nothing gets picked for you while you are away.
          </div>
        </div>
      <% else %>
        <div style="font-size:0.8rem; color:#8b949e; margin-bottom:0.9rem">
          {length(@open)} {if length(@open) == 1, do: "mission is", else: "questions are"}
          holding the factory. Oldest first.
        </div>
        <div :for={inquiry <- @open}>
          <div :if={inquiry[:mission_goal]} style="font-size:0.78rem; color:#8b949e; margin:0 0 0.25rem 0.2rem">
            {String.slice(inquiry.mission_goal, 0, 160)}
          </div>
          <.inquiry_card inquiry={inquiry} draft={@draft[inquiry.id]} mission_link={true} />
        </div>
      <% end %>
    </.live_component>
    """
  end
end
