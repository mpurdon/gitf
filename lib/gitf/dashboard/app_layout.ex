defmodule GiTF.Dashboard.AppLayout do
  @moduledoc """
  LiveComponent that renders the navigation bar and wraps page content.

  Navigation is organized into logical groups:
  - Core: Overview, Missions, Ghosts, Ops activity
  - Pipeline: Costs, Models, Approvals, Merges
  - Infrastructure: Sectors, Shells, Providers
  - Observability: Timeline, Health, Rollback, Autonomy
  """

  use Phoenix.LiveComponent

  alias Phoenix.LiveView.JS
  require GiTF.Ghost.Status, as: GhostStatus

  @prefix "/dashboard"

  @impl true
  def update(assigns, socket) do
    # Subscribe on first mount
    if not Map.get(socket.assigns, :subscribed, false) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:alerts")
    end

    # Drop :flash before assigning — it's reserved by LiveView in components
    safe_assigns = Map.drop(assigns, [:flash])

    {:ok,
     socket
     |> assign(safe_assigns)
     |> assign_new(:subscribed, fn -> true end)
     |> assign_new(:toasts, fn -> Map.get(assigns, :toasts, []) end)}
  end

  @impl true
  def render(assigns) do
    pending_count =
      try do
        length(GiTF.Override.pending_approvals())
      rescue
        _ -> 0
      end

    active_ghosts =
      try do
        GiTF.Ghosts.list(status: GhostStatus.working()) |> length()
      rescue
        _ -> 0
      end

    assigns =
      assigns
      |> assign(:pending_approvals, pending_count)
      |> assign(:active_ghosts, active_ghosts)
      |> assign(:prefix, @prefix)

    ~H"""
    <div>
      <nav class="nav">
        <div class="nav-brand">
          <a href="/" style="color:inherit;text-decoration:none">The <span>GiTF</span></a>
          <span style="font-size:0.65rem;color:#6b7280;font-weight:400;margin-left:0.3rem">v<%= GiTF.version() %></span>
          <%= if @active_ghosts > 0 do %>
            <span class="nav-activity pulse" style="background:#3fb950; margin-left:0.4rem" title={"#{@active_ghosts} ghost(s) working"}></span>
          <% end %>
        </div>
        <div class="nav-links">
          <%!-- Core --%>
          <a href={@prefix} class={if @current_path == "/", do: "active"}>Overview</a>
          <a href={"#{@prefix}/missions"} class={if active?(@current_path, "/missions"), do: "active"}>Missions</a>
          <a href={"#{@prefix}/ghosts"} class={if @current_path == "/ghosts", do: "active"}>Ghosts</a>
          <a href={"#{@prefix}/progress"} class={if @current_path == "/progress", do: "active"}>Activity</a>

          <div class="nav-sep"></div>

          <%!-- Pipeline --%>
          <a href={"#{@prefix}/costs"} class={if @current_path == "/costs", do: "active"}>Costs</a>
          <a href={"#{@prefix}/models"} class={if @current_path == "/models", do: "active"}>Models</a>
          <a href={"#{@prefix}/approvals"} class={if active?(@current_path, "/approvals"), do: "active"}>
            Approvals
            <%= if @pending_approvals > 0 do %>
              <span class="nav-badge nav-badge-orange">{@pending_approvals}</span>
            <% end %>
          </a>
          <a href={"#{@prefix}/merges"} class={if @current_path == "/merges", do: "active"}>Merges</a>

          <div class="nav-sep"></div>

          <%!-- Infrastructure --%>
          <a href={"#{@prefix}/sectors"} class={if @current_path == "/sectors", do: "active"}>Sectors</a>
          <a href={"#{@prefix}/shells"} class={if @current_path == "/shells", do: "active"}>Shells</a>

          <div class="nav-sep"></div>

          <%!-- Observability --%>
          <a href={"#{@prefix}/timeline"} class={if active?(@current_path, "/timeline"), do: "active"}>Timeline</a>
          <a href={"#{@prefix}/health"} class={if @current_path == "/health", do: "active"}>Health</a>
          <a href={"#{@prefix}/links"} class={if @current_path == "/links", do: "active"}>Links</a>
          <a href={"#{@prefix}/rollback"} class={if @current_path == "/rollback", do: "active"}>Rollback</a>
          <div class="nav-sep"></div>
          <a href={"#{@prefix}/providers"} class={if @current_path == "/providers", do: "active"}>Providers</a>
          <a href={"#{@prefix}/settings"} class={if active?(@current_path, "/settings"), do: "active"}>Settings</a>
          <span style="font-size:0.7rem; color:#484f58; cursor:help" title="Press ? for keyboard shortcuts">?</span>
        </div>
      </nav>
      <main class="main">
        <div :if={Phoenix.Flash.get(@flash, :info)} class="flash-info" style="display:flex; justify-content:space-between; align-items:center">
          <span>{Phoenix.Flash.get(@flash, :info)}</span>
          <button phx-click="lv:clear-flash" phx-value-key="info" style="background:none; border:none; color:inherit; cursor:pointer; font-size:1.1rem; padding:0 0.3rem; opacity:0.7">&times;</button>
        </div>
        <div :if={Phoenix.Flash.get(@flash, :error)} class="flash-error" style="display:flex; justify-content:space-between; align-items:center">
          <span>{Phoenix.Flash.get(@flash, :error)}</span>
          <button phx-click="lv:clear-flash" phx-value-key="error" style="background:none; border:none; color:inherit; cursor:pointer; font-size:1.1rem; padding:0 0.3rem; opacity:0.7">&times;</button>
        </div>
        {render_slot(@inner_block)}
      </main>

      <%!-- Toast notifications --%>
      <%= if @toasts != [] do %>
        <div class="toast-container">
          <%= for toast <- Enum.take(@toasts, 5) do %>
            <div id={"toast-#{toast.id}"} class={"toast toast-#{toast.level}"}>
              <span style="flex:1">{toast.message}</span>
              <button
                phx-click={JS.hide(to: "#toast-#{toast.id}", transition: {"transition-opacity duration-200", "opacity-100", "opacity-0"})}
                style="background:none; border:none; color:#6b7280; cursor:pointer; font-size:1rem; padding:0; line-height:1"
              >&times;</button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp active?(current, prefix) do
    current == prefix or String.starts_with?(current, prefix <> "/")
  end
end
