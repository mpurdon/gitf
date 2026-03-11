defmodule GiTF.Dashboard.AppLayout do
  @moduledoc """
  LiveComponent that renders the navigation bar and wraps page content.

  Used as a live_component from each LiveView page so the navigation
  state (active link highlighting) updates without a full page reload.
  """

  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <nav class="nav">
        <div class="nav-brand">The <span>GiTF</span></div>
        <div class="nav-links">
          <a href="/" class={if @current_path == "/", do: "active"}>Overview</a>
          <a href="/quests" class={if @current_path == "/quests", do: "active"}>Quests</a>
          <a href="/ghosts" class={if @current_path == "/ghosts", do: "active"}>Bees</a>
          <a href="/costs" class={if @current_path == "/costs", do: "active"}>Costs</a>
          <a href="/waggles" class={if @current_path == "/waggles", do: "active"}>Waggles</a>
        </div>
      </nav>
      <main class="main">
        <div :if={Phoenix.Flash.get(@flash, :info)} class="flash-info">
          {Phoenix.Flash.get(@flash, :info)}
        </div>
        <div :if={Phoenix.Flash.get(@flash, :error)} class="flash-error">
          {Phoenix.Flash.get(@flash, :error)}
        </div>
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
