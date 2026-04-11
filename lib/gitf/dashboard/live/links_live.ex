defmodule GiTF.Dashboard.LinksLive do
  @moduledoc """
  Link message viewer.

  Lists recent inter-agent messages in reverse chronological order.
  Auto-updates when new links arrive via PubSub subscription, so the
  operator sees real-time message flow without refreshing.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
    end

    links = GiTF.Link.list(limit: 50)

    {:ok,
     socket
     |> assign(:page_title, "Links")
     |> assign(:current_path, "/links")
     |> assign(:links, links)
     |> assign(:expanded, MapSet.new())
     |> assign(:filter_subject, "all")
     |> init_toasts()}
  end

  @impl true
  def handle_info({:waggle_received, waggle}, socket) do
    links = GiTF.Link.list(limit: 50)
    {:noreply, socket |> maybe_apply_toast(waggle) |> assign(:links, links)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, reload_links(socket)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id),
        do: MapSet.delete(socket.assigns.expanded, id),
        else: MapSet.put(socket.assigns.expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("filter_subject", %{"subject" => subject}, socket) do
    {:noreply, socket |> assign(:filter_subject, subject) |> reload_links()}
  end

  defp reload_links(socket) do
    all = GiTF.Link.list(limit: 100)

    filtered =
      case socket.assigns.filter_subject do
        "all" -> all
        subject -> Enum.filter(all, &(&1.subject == subject))
      end
      |> Enum.take(50)

    assign(socket, :links, filtered)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1.25rem">
        <h1 class="page-title" style="margin-bottom:0">Link Messages</h1>
        <button phx-click="refresh" style="background:#1f6feb33; color:#58a6ff; border:1px solid #1f6feb55; padding:0.4rem 1rem; border-radius:6px; cursor:pointer; font-size:0.85rem">
          Refresh
        </button>
      </div>

      <%!-- Subject filter --%>
      <div style="display:flex; gap:0.25rem; margin-bottom:1rem; flex-wrap:wrap">
        <%= for subject <- ["all", "job_complete", "job_failed", "quest_advance", "human_approval", "merge_failed", "pr_created", "context_handoff"] do %>
          <button
            phx-click="filter_subject"
            phx-value-subject={subject}
            class={"btn #{if @filter_subject == subject, do: "btn-blue", else: "btn-grey"}"}
            style="font-size:0.7rem; padding:0.2rem 0.5rem"
          >
            {subject}
          </button>
        <% end %>
      </div>

      <div class="panel">
        <%= if @links == [] do %>
          <div class="empty">No messages found. Messages appear here as ghosts and the Major communicate.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th></th>
                <th></th>
                <th>From</th>
                <th>To</th>
                <th>Subject</th>
                <th>Time</th>
              </tr>
            </thead>
            <tbody>
              <%= for link_msg <- @links do %>
                <tr class={"detail-toggle #{unless link_msg.read, do: "link_msg-unread"}"} phx-click="toggle" phx-value-id={link_msg.id}>
                  <td style="width:1rem; cursor:pointer">
                    {if MapSet.member?(@expanded, link_msg.id), do: "v", else: ">"}
                  </td>
                  <td style="width:1rem">
                    <span class={"badge #{if link_msg.read, do: "badge-grey", else: "badge-blue"}"} style="font-size:0.65rem">
                      {if link_msg.read, do: "R", else: "N"}
                    </span>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem">{link_msg.from}</td>
                  <td style="font-family:monospace; font-size:0.8rem">{link_msg.to}</td>
                  <td class={unless link_msg.read, do: "link_msg-subject"}>{link_msg.subject || "(no subject)"}</td>
                  <td style="font-size:0.8rem; color:#8b949e">{format_timestamp(link_msg.inserted_at)}</td>
                </tr>
                <%= if MapSet.member?(@expanded, link_msg.id) do %>
                  <tr>
                    <td colspan="6" style="padding:0.5rem 1rem; background:#0d1117; border-top:none">
                      <div style="font-size:0.8rem; color:#c9d1d9; white-space:pre-wrap; font-family:monospace; max-height:200px; overflow-y:auto">
                        {link_msg.body || "(empty)"}
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

  defp format_timestamp(nil), do: "-"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_), do: "-"
end
