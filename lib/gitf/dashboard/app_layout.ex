defmodule GiTF.Dashboard.AppLayout do
  @moduledoc """
  LiveComponent that renders the navigation bar and wraps page content.

  Used as a live_component from each LiveView page so the navigation
  state (active link highlighting) updates without a full page reload.
  """

  use Phoenix.LiveComponent

  @prefix "/dashboard"

  @impl true
  def render(assigns) do
    pending_count =
      try do
        length(GiTF.Override.pending_approvals())
      rescue
        _ -> 0
      end

    assigns =
      assigns
      |> assign(:pending_approvals, pending_count)
      |> assign(:prefix, @prefix)

    ~H"""
    <div>
      <nav class="nav">
        <div class="nav-brand"><a href="/" style="color:inherit;text-decoration:none">The <span>GiTF</span></a> <span style="font-size:0.7rem;color:#6b7280;font-weight:400;margin-left:0.4rem">v<%= GiTF.version() %></span></div>
        <div class="nav-links">
          <a href={@prefix} class={if @current_path == "/", do: "active"}>Overview</a>
          <a href={"#{@prefix}/missions"} class={if active?(@current_path, "/missions"), do: "active"}>Missions</a>
          <a href={"#{@prefix}/ghosts"} class={if @current_path == "/ghosts", do: "active"}>Ghosts</a>
          <a href={"#{@prefix}/costs"} class={if @current_path == "/costs", do: "active"}>Costs</a>
          <a href={"#{@prefix}/links"} class={if @current_path == "/links", do: "active"}>Links</a>
          <a href={"#{@prefix}/approvals"} class={if active?(@current_path, "/approvals"), do: "active"}>
            Approvals
            <%= if @pending_approvals > 0 do %>
              <span class="nav-badge nav-badge-orange">{@pending_approvals}</span>
            <% end %>
          </a>
          <a href={"#{@prefix}/sectors"} class={if @current_path == "/sectors", do: "active"}>Sectors</a>
          <a href={"#{@prefix}/autonomy"} class={if @current_path == "/autonomy", do: "active"}>Autonomy</a>
          <a href={"#{@prefix}/providers"} class={if @current_path == "/providers", do: "active"}>Providers</a>
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
    </div>
    """
  end

  defp active?(current, prefix) do
    current == prefix or String.starts_with?(current, prefix <> "/")
  end
end
