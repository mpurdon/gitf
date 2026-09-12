defmodule GiTF.Dashboard.ConsoleLive do
  @moduledoc """
  The GiTF Console: one surface from the Cabinet down.

  Mounted at `/console` beside the Cabinet Console it will replace, because the
  Cabinet is the fleet's only always-on node and parity gets proven before
  anything is switched. `test/gitf/dashboard/console/parity_test.exs` holds this
  module against every capability the old console has.

  Three things it does differently.

  **Scope lives in the URL.** The old console kept view and selection in socket
  assigns, so nothing was bookmarkable and the back button did nothing. Every
  object here is an address, and the tree, the crumbs and the workspace are
  three readings of that one fact.

  **Rendering does no I/O.** `CabinetLive.load/1` shelled out to
  `aws ec2 describe-instances` per ministry and made an HTTP call per running
  factory — on mount, on the disconnected render, and every twenty seconds, per
  open console. Worse, it *wrote* to the registry from a render path. Here the
  watcher owns that work and the Console reads what it stored, pushed over
  PubSub the moment it changes, so the screen is live rather than up-to-20s-stale.

  **Leaving for the factory is one motion.** `Catwalk ↗` wakes a sleeping box
  and lands on the page you asked for, rather than failing because the thing you
  clicked is asleep.
  """

  use Phoenix.LiveView, layout: {GiTF.Dashboard.Console.Layouts, :root}

  import GiTF.Dashboard.Console.Components

  alias GiTF.Cabinet.{Activity, Fleet, Gate, Registry, Snapshot}
  alias GiTF.Dashboard.Console.{Format, Pages, Scope, Tree}

  @activity_limit 40
  @inbox_limit 200
  @open_timeout_ms 180_000

  # ==========================================================================
  # Lifecycle
  # ==========================================================================

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "cabinet:activity")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "cabinet:inbox")
    end

    {:ok,
     socket
     |> assign(
       actor: actor(socket),
       filter: "all",
       editing: nil,
       opening: nil,
       page_title: "GiTF Console"
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = Scope.from_params(params)
    {:noreply, socket |> assign(scope: scope) |> assign_object()}
  end

  # A record changed somewhere — the watcher observed a transition, the Gate
  # queued a delivery, someone acted. Re-read; it is all ETS.
  @impl true
  def handle_info({:cabinet_activity, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:inbox_queued, _}, socket), do: {:noreply, load(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:open, {:ok, :ok}, socket) do
    case socket.assigns.opening do
      %{url: url} -> {:noreply, redirect(socket, external: url)}
      _ -> {:noreply, assign(socket, opening: nil)}
    end
  end

  def handle_async(:open, {:ok, other}, socket) do
    {:noreply,
     socket
     |> assign(opening: nil)
     |> put_flash(:error, "The factory did not come up: #{describe(other)}")}
  end

  def handle_async(:open, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(opening: nil) |> put_flash(:error, "Wake cancelled: #{describe(reason)}")}
  end

  # ==========================================================================
  # Loading — cheap by construction
  # ==========================================================================

  defp load(socket) do
    socket
    |> assign(
      ministries: Registry.list(),
      activity: Activity.list(@activity_limit),
      inbox: Gate.inbox() |> Enum.take(@inbox_limit),
      cabinet: cabinet_facts()
    )
    |> assign_object()
  end

  defp cabinet_facts do
    %{
      host: GiTF.Config.server_url() || "—",
      release: GiTF.version(),
      ingress: "/hooks/<slug> · /relay/<slug>"
    }
  end

  # Resolves the scope's slug to the record it names. A stale link — a retired
  # ministry, a renamed slug — lands on the Cabinet with a word about why,
  # rather than rendering a page about nothing.
  defp assign_object(%{assigns: %{scope: %Scope{ministry: nil}}} = socket),
    do: assign(socket, ministry: nil)

  defp assign_object(%{assigns: %{scope: %Scope{ministry: "new"}}} = socket),
    do: assign(socket, ministry: %{slug: nil}, editing: "new")

  defp assign_object(%{assigns: %{scope: %Scope{ministry: slug}} = assigns} = socket) do
    case Enum.find(assigns.ministries, &(&1.slug == slug)) do
      nil -> assign(socket, ministry: nil)
      m -> assign(socket, ministry: m)
    end
  end

  defp assign_object(socket), do: socket

  # ==========================================================================
  # Render
  # ==========================================================================

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:nodes, Tree.build(assigns.ministries, assigns.scope, tree_counts(assigns)))
      |> assign(:crumbs, Scope.crumbs(assigns.scope, &ministry_name(assigns.ministries, &1)))

    ~H"""
    <div class="console">
      <nav class="icons" aria-label="Sections">
        <.link
          patch={Scope.path(@scope, :cabinet)}
          title="Fleet"
          aria-current={if @scope.level not in [:activity], do: "page"}
        >▦</.link>
        <.link
          patch={Scope.path(@scope, :activity)}
          title="Activity"
          class={waiting(@inbox) > 0 && "badge"}
          data-n={waiting(@inbox)}
          aria-current={if @scope.level == :activity, do: "page"}
        >⧗</.link>
        <span class="spacer"></span>
      </nav>

      <.tree nodes={@nodes} />

      <div class="pane ws">
        <.scopebar crumbs={@crumbs}>
          <span :if={@opening} class="pill recon">
            waking {@opening.slug}…
            <button phx-click="cancel_open" style="color:inherit;text-decoration:underline">stop waiting</button>
          </span>
          <.pill tone={:ok}>● live</.pill>
        </.scopebar>

        <.head
          scope={@scope}
          ministry={@ministry}
          ministries={@ministries}
          cabinet={@cabinet}
          inbox={@inbox}
          opening={@opening}
        />
        <.tabs scope={@scope} />

        <div class="body">
          <.banner :if={@scope.ministry && is_nil(@ministry) && @scope.ministry != "new"} tone={:warn}>
            No ministry called <b>{@scope.ministry}</b> is registered. It may have been retired.
          </.banner>
          <.page {assigns} />
        </div>
      </div>
    </div>

    <div :if={Phoenix.Flash.get(@flash, :info)} class="flash">
      {Phoenix.Flash.get(@flash, :info)}
      <button phx-click="lv:clear-flash" phx-value-key="info">dismiss</button>
    </div>
    <div :if={Phoenix.Flash.get(@flash, :error)} class="flash err">
      {Phoenix.Flash.get(@flash, :error)}
      <button phx-click="lv:clear-flash" phx-value-key="error">dismiss</button>
    </div>
    """
  end

  # -- object heads ----------------------------------------------------------

  defp head(%{scope: %{level: :cabinet}} = assigns) do
    ~H"""
    <.object_head kind="Cabinet" name="Cabinet" sub={"#{@cabinet.host} · #{@cabinet.ingress}"}>
      <:badges><.pill tone={:ok}>● always on</.pill></:badges>
      <:metrics>
        <.metric label="Factories" value={"#{awake(@ministries)} of #{length(@ministries)} awake"} />
        <.metric label="Waiting on you" value={waiting(@inbox)} tone={waiting(@inbox) > 0 && :warn} />
        <.metric label="Activations" value={length(@inbox)} />
        <.metric label="Release" value={@cabinet.release} />
      </:metrics>
    </.object_head>
    """
  end

  defp head(%{scope: %{level: :activity}} = assigns) do
    ~H"""
    <.object_head kind="Fleet" name="Activity" sub="what the factory did, and which of it wants you">
      <:badges>
        <.pill tone={if waiting(@inbox) > 0, do: :warn, else: :ok}>
          {if waiting(@inbox) > 0, do: "#{waiting(@inbox)} waiting", else: "nothing waiting"}
        </.pill>
      </:badges>
    </.object_head>
    """
  end

  defp head(%{ministry: nil} = assigns) do
    ~H"""
    <.object_head kind="Ministry" name={@scope.ministry || "Unknown"} />
    """
  end

  defp head(%{scope: %{level: :ministry}} = assigns) do
    ~H"""
    <.object_head
      kind="Ministry"
      name={@ministry[:name] || @ministry.slug}
      sub={"#{@ministry.slug} · #{@ministry[:instance_id] || "no instance"} · #{@ministry[:url] || "no url"}"}
    >
      <:badges>
        <.pill tone={Format.state_tone(@ministry)}>● {Format.state_label(@ministry)}</.pill>
        <.pill>mode {@ministry[:mode] || "normal"}</.pill>
      </:badges>
      <:metrics>
        <.metric label="State" value={Format.state_for(@ministry)} />
        <.metric label="Idle-stop" value={Format.sleeps_in(@ministry)} />
        <.metric label="Release" value={Format.version(@ministry)} />
        <.metric label="Load" value={Format.load(@ministry)} />
        <.metric label="Spend" value={Format.spend_line(@ministry)} tone={Format.cap_tone(@ministry)} />
      </:metrics>
      <:actions>
        <.ministry_actions ministry={@ministry} opening={assigns[:opening]} />
      </:actions>
    </.object_head>
    """
  end

  defp head(%{scope: %{level: :ruleset}} = assigns) do
    ~H"""
    <.object_head
      kind="Ministry configuration"
      name="Activation ruleset"
      sub={"governs #{@ministry[:name] || @ministry.slug} · first hit wins · anything undecided queues"}
    >
      <:badges>
        <.pill tone={:ok}>in force</.pill>
        <.pill>mode {@ministry[:mode] || "normal"}</.pill>
      </:badges>
      <:metrics>
        <.metric label="Rules" value={length(Format.rule_rows(@ministry))} />
        <.metric label="Source" value={if @ministry[:rules], do: "this ministry", else: "fleet default"} />
      </:metrics>
    </.object_head>
    """
  end

  defp head(%{scope: %{level: :registration}} = assigns) do
    ~H"""
    <.object_head
      kind="Ministry configuration"
      name="Registration"
      sub={
        if @ministry[:slug],
          do: "the Cabinet's record of #{@ministry[:name] || @ministry.slug} — secrets by NAME only",
          else: "a new ministry — the Cabinet needs a name, a URL and an instance to start"
      }
    >
      <:badges>
        <.pill :if={@ministry[:slug]} tone={if @ministry[:instance_id], do: :ok, else: :warn}>
          {if @ministry[:instance_id], do: "complete", else: "incomplete"}
        </.pill>
      </:badges>
    </.object_head>
    """
  end

  # Every action the old console had, labelled once. Which appear depends on
  # the state — the cold-start path is the one an operator needs most and the
  # easiest to lose, so Wake and Wake & open are first when a box is asleep.
  attr(:ministry, :map, required: true)
  attr(:opening, :any, default: nil)

  defp ministry_actions(assigns) do
    ~H"""
    <%= if Format.running?(@ministry) do %>
      <button class="btn" phx-click="stop" phx-value-id={@ministry.id}>Sleep now</button>
      <button class="btn" phx-click="snapshot" phx-value-id={@ministry.id}>Refresh</button>
      <button class="btn" phx-click="open_factory" phx-value-id={@ministry.id}>Catwalk ↗</button>
    <% else %>
      <button
        class="btn pri"
        phx-click="wake"
        phx-value-id={@ministry.id}
        disabled={is_nil(@ministry[:instance_id]) or @opening != nil}
      >Wake</button>
      <button
        class="btn"
        phx-click="open_factory"
        phx-value-id={@ministry.id}
        disabled={is_nil(@ministry[:url]) or @opening != nil}
      >Wake &amp; open ↗</button>
      <span class="note">
        or bookmark <code>{Scope.root()}/wake/{@ministry.slug}</code> to do both from cold
      </span>
    <% end %>
    """
  end

  # -- bodies ----------------------------------------------------------------

  defp page(%{scope: %{level: :cabinet}} = assigns) do
    ~H"""
    <Pages.cabinet
      scope={@scope}
      ministries={@ministries}
      activity={@activity}
      inbox={@inbox}
      cabinet={@cabinet}
    />
    """
  end

  defp page(%{scope: %{level: :activity}} = assigns) do
    ~H"""
    <Pages.activity scope={@scope} activity={@activity} inbox={@inbox} filter={@filter} />
    """
  end

  defp page(%{ministry: nil} = assigns) do
    ~H"""
    """
  end

  defp page(%{scope: %{level: :ministry}} = assigns) do
    ~H"""
    <Pages.ministry scope={@scope} ministry={@ministry} inbox={for_ministry(@inbox, @ministry)} />
    """
  end

  defp page(%{scope: %{level: :ruleset}} = assigns) do
    ~H"""
    <Pages.ruleset scope={@scope} ministry={@ministry} inbox={for_ministry(@inbox, @ministry)} />
    """
  end

  defp page(%{scope: %{level: :registration}} = assigns) do
    ~H"""
    <Pages.registration scope={@scope} ministry={@ministry} editing={editing?(assigns)} />
    """
  end

  # ==========================================================================
  # Events — every capability the Cabinet Console had
  # ==========================================================================

  @impl true
  def handle_event("filter", %{"filter" => f}, socket), do: {:noreply, assign(socket, filter: f)}

  def handle_event("wake", %{"id" => id}, socket) do
    with_ministry(socket, id, fn m, socket ->
      case Fleet.wake(m) do
        :ok ->
          record(socket, "wake", m.slug, "starting")

          {:noreply,
           socket |> put_flash(:info, "Waking #{m.slug} — healthy in about a minute.") |> load()}

        other ->
          {:noreply, put_flash(socket, :error, "Wake failed: #{describe(other)}")}
      end
    end)
  end

  def handle_event("stop", %{"id" => id}, socket) do
    with_ministry(socket, id, fn m, socket ->
      case Fleet.stop(m) do
        :ok ->
          record(socket, "stop", m.slug, "stopping")
          {:noreply, socket |> put_flash(:info, "Putting #{m.slug} to sleep.") |> load()}

        other ->
          {:noreply, put_flash(socket, :error, "Could not stop it: #{describe(other)}")}
      end
    end)
  end

  def handle_event("snapshot", %{"id" => id}, socket) do
    with_ministry(socket, id, fn m, socket ->
      case Snapshot.refresh(m) do
        :ok ->
          {:noreply, socket |> put_flash(:info, "Refreshed from the factory.") |> load()}

        other ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "That needs a running, reachable factory: #{describe(other)}"
           )}
      end
    end)
  end

  def handle_event("set_mode", %{"id" => id, "mode" => mode}, socket) do
    with_ministry(socket, id, fn m, socket ->
      case Registry.set_mode(id, mode) do
        {:ok, _} ->
          record(socket, "mode", m.slug, mode)
          {:noreply, socket |> put_flash(:info, "#{m.slug} is now #{mode}.") |> load()}

        other ->
          {:noreply, put_flash(socket, :error, "Mode not changed: #{describe(other)}")}
      end
    end)
  end

  # Wake if needed, then land on the factory. The old console offered this only
  # from the fleet view and only to the factory's home page; the point of it is
  # that a link into a sleeping factory should still work.
  def handle_event("open_factory", %{"id" => id} = params, socket) do
    with_ministry(socket, id, fn m, socket ->
      to = Map.get(params, "to", "/dashboard")

      cond do
        is_nil(m[:url]) ->
          {:noreply, put_flash(socket, :error, "#{m.slug} has no URL to open.")}

        Format.running?(m) ->
          {:noreply, redirect(socket, external: factory_url(m, to))}

        true ->
          record(socket, "wake", m.slug, "starting · will open")
          {:noreply, start_open(socket, m, to)}
      end
    end)
  end

  def handle_event("cancel_open", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:open)
     |> assign(opening: nil)
     |> put_flash(:info, "Stopped waiting. The factory is still coming up.")}
  end

  def handle_event("start_entry", %{"id" => id}, socket) do
    case Gate.start_queued(id) do
      :ok ->
        record(socket, "start_queued", id, "ok")

        {:noreply,
         socket |> put_flash(:info, "Starting it — waking the factory and forwarding.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Could not start it: #{describe(other)}")}
    end
  end

  def handle_event("dismiss_entry", %{"id" => id}, socket) do
    case Gate.dismiss_queued(id) do
      :ok ->
        record(socket, "dismiss_queued", id, "ok")
        {:noreply, socket |> put_flash(:info, "Dismissed. Nothing was woken.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Could not dismiss it: #{describe(other)}")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket), do: {:noreply, assign(socket, editing: id)}
  def handle_event("edit", _params, socket), do: {:noreply, assign(socket, editing: "new")}
  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save_ministry", %{"ministry_id" => id} = params, socket) do
    case Registry.edit(id, Map.drop(params, ["ministry_id", "_target"])) do
      {:ok, m} ->
        record(socket, "edit", m.slug, "ok")

        {:noreply,
         socket |> assign(editing: nil) |> put_flash(:info, "Registration saved.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Not saved: #{describe(other)}")}
    end
  end

  def handle_event("save_ministry", params, socket) do
    case Registry.create(Map.drop(params, ["_target"])) do
      {:ok, m} ->
        record(socket, "register", m.slug, "ok")

        {:noreply,
         socket
         |> assign(editing: nil)
         |> put_flash(:info, "#{m.slug} registered.")
         |> load()
         |> push_patch(to: Scope.path(socket.assigns.scope, :ministry, ministry: m.slug))}

      other ->
        {:noreply, put_flash(socket, :error, "Not registered: #{describe(other)}")}
    end
  end

  # ==========================================================================
  # Internals
  # ==========================================================================

  defp with_ministry(socket, id, fun) do
    case Registry.get(id) do
      %{} = m -> fun.(m, socket)
      _ -> {:noreply, put_flash(socket, :error, "That ministry no longer exists.")}
    end
  end

  defp start_open(socket, m, to) do
    socket
    |> assign(opening: %{slug: m.slug, url: factory_url(m, to)})
    |> start_async(:open, fn -> Fleet.wake_and_await(m, @open_timeout_ms) end)
  end

  defp factory_url(m, to) do
    base = String.trim_trailing(m[:url] || "", "/")
    base = if String.starts_with?(base, "http"), do: base, else: "https://" <> base
    base <> to
  end

  defp record(socket, action, target, result),
    do: Activity.record(socket.assigns.actor, action, target, result)

  defp actor(socket) do
    case get_connect_params(socket) do
      _ -> tailnet_actor(socket)
    end
  end

  defp tailnet_actor(socket) do
    case socket.assigns[:tailnet_identity] do
      %{login: login} when is_binary(login) -> login
      _ -> "console"
    end
  end

  defp for_ministry(inbox, %{slug: slug}), do: Enum.filter(inbox, &(&1[:ministry_slug] == slug))
  defp for_ministry(inbox, _), do: inbox

  defp waiting(inbox), do: inbox |> Format.queued() |> length()

  defp tree_counts(assigns) do
    %{
      activations: length(assigns.inbox),
      needs: waiting(assigns.inbox),
      events: length(assigns.activity)
    }
  end

  defp awake(ministries) when is_list(ministries),
    do: Enum.count(ministries, &Format.running?/1)

  defp awake(_), do: 0

  defp ministry_name(ministries, slug) do
    case Enum.find(ministries, &(&1.slug == slug)) do
      %{name: name} when is_binary(name) -> name
      _ -> slug
    end
  end

  defp editing?(%{editing: editing, ministry: m}),
    do: editing != nil and editing in [m[:id], "new"]

  defp editing?(_), do: false

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 200)
end
