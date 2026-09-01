defmodule GiTF.Dashboard.AppLayout do
  @moduledoc """
  LiveComponent that renders the navigation bar and wraps page content.

  Navigation is the seven operator concepts of the GiTF Control Surface
  plan (§03) — a dark icon rail — with each concept's pages in a
  secondary bar. Capabilities are never top-level items.
  """

  use Phoenix.LiveComponent

  import Phoenix.HTML, only: [raw: 1]

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

    # `:flash` is reserved by LiveView inside components, so it cannot be
    # assigned under that name — but dropping it while `render/1` still
    # read `@flash` meant the component resolved its OWN empty flash and
    # every dashboard flash rendered as nothing. put_flash/3 across the
    # whole Catwalk was write-only: the approvals page reported a failed
    # approve into a void. Carry the parent's flash under a name of our
    # own and render THAT.
    safe_assigns =
      assigns
      |> Map.drop([:flash])
      |> Map.put(:parent_flash, Map.get(assigns, :flash) || %{})

    {:ok,
     socket
     |> assign(safe_assigns)
     |> assign_new(:subscribed, fn -> true end)
     |> assign_new(:confirming_stop, fn -> false end)
     |> assign_new(:stop_result, fn -> nil end)
     |> assign_new(:toasts, fn -> Map.get(assigns, :toasts, []) end)}
  end

  @impl true
  def handle_event("confirm_stop_all", _params, socket),
    do: {:noreply, assign(socket, :confirming_stop, true)}

  def handle_event("cancel_stop_all", _params, socket),
    do: {:noreply, assign(socket, :confirming_stop, false)}

  # Stops every working ghost. Deliberately does NOT kill their missions:
  # this is "put the tools down", not "throw the work away". Ops whose ghost
  # is stopped fail and follow the workflow's normal retry path, so a mission
  # left active can start new ghosts afterwards — kill the mission from its
  # detail page if you want it to stay stopped.
  def handle_event("stop_all", _params, socket) do
    working = GiTF.Ghosts.list(status: GhostStatus.working())
    stopped = Enum.count(working, fn g -> GiTF.Ghosts.stop(g[:id]) == :ok end)

    GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
      type: :emergency_stop,
      message:
        "Stop All triggered from the dashboard: #{stopped}/#{length(working)} ghosts stopped"
    })

    # Result stays in the component's own assigns. Messaging the parent would
    # require every page hosting this layout to carry a matching handle_info,
    # and the ones without a catch-all would crash on it.
    {:noreply,
     socket
     |> assign(:confirming_stop, false)
     |> assign(:stop_result, "Stopped #{stopped}/#{length(working)}")}
  end

  @impl true
  def render(assigns) do
    pending_count =
      try do
        length(GiTF.Override.pending_approvals())
      rescue
        _ -> 0
      end

    # Every one of these is a mission that is stopped RIGHT NOW waiting on
    # the person reading this nav bar. The badge is the only thing that
    # tells them, from any page, that the factory is holding.
    open_questions =
      try do
        length(GiTF.Inquiry.list_open())
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
      |> assign(:open_questions, open_questions)
      |> assign(:active_ghosts, active_ghosts)
      |> assign(:prefix, @prefix)

    ~H"""
    <div class="layout">
      <nav class="rail">
        <a href="/" class="rail-logo" title={"GiTF v#{GiTF.version()}"}>
          G
          <span :if={@active_ghosts > 0} class="nav-activity pulse" style="background:var(--ok)" title={"#{@active_ghosts} ghost(s) working"}></span>
        </a>
        <a :for={{key, label, icon, _children} <- concepts()} href={concept_home(key)} class={["rail-item", concept_for(@current_path) == key && "active"]}>
          <span class="rail-badge-anchor">
            {raw(icon)}
            <span :if={key == :operations and @pending_approvals + @open_questions > 0} class="rail-count">{@pending_approvals + @open_questions}</span>
          </span>
          {label}
        </a>
        <div class="rail-spacer"></div>
        <button
          :if={@active_ghosts > 0 and not @confirming_stop}
          phx-click="confirm_stop_all"
          phx-target={@myself}
          class="rail-item rail-stop"
          title={"Stop all #{@active_ghosts} working ghost(s)"}
        >
          <svg class="rail-ico" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
          Stop all
        </button>
        <span :if={@confirming_stop} class="rail-stop-confirm">
          Stop {@active_ghosts}?
          <button phx-click="stop_all" phx-target={@myself} class="yes">Yes</button>
          <button phx-click="cancel_stop_all" phx-target={@myself}>No</button>
        </span>
        <span :if={@stop_result && @active_ghosts == 0} class="rail-stop-confirm">{@stop_result}</span>
        <span class="rail-version">v{GiTF.version()}</span>
      </nav>
      <div style="min-width:0">
        <div class="subnav">
          <a :for={{label, path, badge} <- children_for(concept_for(@current_path), @pending_approvals, @open_questions)} href={"#{@prefix}#{path}"} class={(@current_path == path or (path != "/" and active?(@current_path, path))) && "active"}>
            {label}
            <span :if={badge && badge > 0} class="nav-badge nav-badge-orange">{badge}</span>
          </a>
        </div>
        <main class="main">
          <div :if={Phoenix.Flash.get(@parent_flash, :info)} class="flash-info" style="display:flex; justify-content:space-between; align-items:center">
            <span>{Phoenix.Flash.get(@parent_flash, :info)}</span>
            <button phx-click="lv:clear-flash" phx-value-key="info" style="background:none; border:none; color:inherit; cursor:pointer; font-size:1.1rem; padding:0 0.3rem; opacity:0.7">&times;</button>
          </div>
          <div :if={Phoenix.Flash.get(@parent_flash, :error)} class="flash-error" style="display:flex; justify-content:space-between; align-items:center">
            <span>{Phoenix.Flash.get(@parent_flash, :error)}</span>
            <button phx-click="lv:clear-flash" phx-value-key="error" style="background:none; border:none; color:inherit; cursor:pointer; font-size:1.1rem; padding:0 0.3rem; opacity:0.7">&times;</button>
          </div>
          {render_slot(@inner_block)}
        </main>
      </div>

      <%!-- Toast notifications --%>
      <%= if @toasts != [] do %>
        <div class="toast-container">
          <%= for toast <- Enum.take(@toasts, 5) do %>
            <div id={"toast-#{toast.id}"} class={"toast toast-#{toast.level}"}>
              <span style="flex:1">{toast.message}</span>
              <button
                phx-click={JS.hide(to: "#toast-#{toast.id}", transition: {"transition-opacity duration-200", "opacity-100", "opacity-0"})}
                style="background:none; border:none; color:var(--muted); cursor:pointer; font-size:1rem; padding:0; line-height:1"
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

  # -- the seven concepts (GiTF Control Surface plan §03) ----------------------

  @concept_paths %{
    overview: ["/", "/progress", "/costs"],
    operations: [
      "/missions",
      "/approvals",
      "/questions",
      "/merges",
      "/ghosts",
      "/shells",
      "/links"
    ],
    systems: ["/health", "/providers", "/models"],
    resources: ["/sectors", "/rollback"],
    investigations: ["/timeline"],
    automation: ["/workflows", "/autonomy", "/studio"],
    administration: ["/settings"]
  }

  defp concept_for(current_path) do
    Enum.find_value(@concept_paths, :overview, fn {concept, paths} ->
      Enum.any?(paths, fn
        "/" -> current_path == "/"
        p -> current_path == p or String.starts_with?(current_path, p <> "/")
      end) && concept
    end)
  end

  defp concept_home(:overview), do: "/dashboard/"
  defp concept_home(concept), do: "/dashboard" <> hd(@concept_paths[concept])

  defp children_for(concept, approvals, questions) do
    case concept do
      :overview ->
        [{"Overview", "/", nil}, {"Activity", "/progress", nil}, {"Costs", "/costs", nil}]

      :operations ->
        [
          {"Missions", "/missions", nil},
          {"Approvals", "/approvals", approvals},
          {"Questions", "/questions", questions},
          {"Merges", "/merges", nil},
          {"Ghosts", "/ghosts", nil},
          {"Shells", "/shells", nil},
          {"Links", "/links", nil}
        ]

      :systems ->
        [{"Health", "/health", nil}, {"Providers", "/providers", nil}, {"Models", "/models", nil}]

      :resources ->
        [{"Sectors", "/sectors", nil}, {"Rollback", "/rollback", nil}]

      :investigations ->
        [{"Timeline", "/timeline", nil}]

      :automation ->
        [
          {"Workflows", "/workflows", nil},
          {"Autonomy", "/autonomy", nil},
          {"Studio", "/studio", nil}
        ]

      :administration ->
        [{"Settings", "/settings", nil}]
    end
  end

  defp concepts do
    [
      {:overview, "Overview",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><rect x="3.5" y="3.5" width="7.5" height="7.5" rx="2"/><rect x="13" y="3.5" width="7.5" height="7.5" rx="2"/><rect x="3.5" y="13" width="7.5" height="7.5" rx="2"/><rect x="13" y="13" width="7.5" height="7.5" rx="2"/></svg>),
       nil},
      {:operations, "Operations",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><path d="M3.5 13.5 6 5.5h12l2.5 8"/><path d="M3.5 13.5V18a1.5 1.5 0 0 0 1.5 1.5h14a1.5 1.5 0 0 0 1.5-1.5v-4.5h-5a3.5 3.5 0 0 1-7 0h-5z"/></svg>),
       nil},
      {:systems, "Systems",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="16" height="6.5" rx="1.5"/><path d="M7.2 7.2h.01M7.2 16.7h.01"/></svg>),
       nil},
      {:resources, "Resources",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><path d="M4 7.5A1.5 1.5 0 0 1 5.5 6h4l2 2.5h7A1.5 1.5 0 0 1 20 10v7.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z"/></svg>),
       nil},
      {:investigations, "Investigate",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6"/><path d="m15.5 15.5 4.5 4.5"/></svg>),
       nil},
      {:automation, "Automation",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2.2"/><circle cx="8" cy="17" r="2.2"/></svg>),
       nil},
      {:administration, "Admin",
       ~s(<svg class="rail-ico" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 4v2.4M12 17.6V20M4 12h2.4M17.6 12H20M6.3 6.3l1.7 1.7M16 16l1.7 1.7M17.7 6.3 16 8M8 16l-1.7 1.7"/></svg>),
       nil}
    ]
  end
end
