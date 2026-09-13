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

  # The root layout is set by the router's `live_session` — declaring it here as
  # an inner layout is what nested the Console's whole document inside the
  # Cabinet's.
  use Phoenix.LiveView

  import GiTF.Dashboard.Console.Components

  alias GiTF.Cabinet.{Activity, Fleet, Gate, Prefs, Registry, Ruleset, Snapshot}
  alias GiTF.Dashboard.Console.{Events, Format, Pages, Scope, Tree}

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
       # handle_params replaces both a beat later; they exist here so `load/1`
       # has one code path rather than a clause that silently skips assigns.
       scope: %Scope{level: :cabinet},
       filters: Events.blank(),
       editing: nil,
       editing_rule: -1,
       opening: nil,
       needs_open: true,
       needs_config_open: false,
       page_title: "GiTF Console"
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = Scope.from_params(params)

    # Filters live in the query string, so a filtered view is a link — which is
    # what makes an "investigation" a name attached to a URL rather than a
    # feature that needs its own machinery.
    socket =
      socket
      |> assign(scope: scope, filters: Events.from_params(params))
      |> assign_object()
      |> assign_stream()

    # /console/wake/<slug> is the cold bookmark: it is an act, not a place, so
    # it starts the wake and settles on the ministry rather than rendering a
    # page of its own. Landing here from a phone with the fleet asleep is the
    # single path that has to work, so it must not depend on the Console
    # already being open.
    if scope.level == :wake do
      {:noreply, wake_and_open(socket)}
    else
      {:noreply, socket}
    end
  end

  defp wake_and_open(%{assigns: %{ministry: nil, scope: scope}} = socket) do
    socket
    |> put_flash(:error, "No ministry called #{scope.ministry} is registered.")
    |> push_patch(to: Scope.path(scope, :cabinet))
  end

  defp wake_and_open(%{assigns: %{ministry: m, scope: scope}} = socket) do
    socket = push_patch(socket, to: Scope.path(scope, :ministry, ministry: m.slug))

    cond do
      is_nil(m[:url]) ->
        put_flash(socket, :error, "#{m.slug} has no URL to open.")

      Format.running?(m) ->
        redirect(socket, external: factory_url(m, "/dashboard"))

      true ->
        record(socket, "wake", m.slug, "starting · will open")
        start_open(socket, m, "/dashboard")
    end
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
    |> assign_stream()
  end

  # The stream is derived, never stored: two ETS reads and a sort, which is
  # cheaper than keeping a third copy of the truth in sync with the other two.
  defp assign_stream(%{assigns: %{scope: scope}} = socket) do
    events = Events.build(socket.assigns.inbox, socket.assigns.activity, scope)
    kinds = Prefs.needs_kinds()

    socket
    |> assign(
      events: events,
      visible: Events.filter(events, socket.assigns.filters),
      needs: Enum.filter(events, &(&1.needs && to_string(&1.kind) in kinds)),
      needs_kinds: kinds,
      investigations: saved_investigations(scope)
    )
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
    <div class={["console", @scope.level == :activity && "facets-on"]}>
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

      <Pages.facets
        :if={@scope.level == :activity}
        events={@events}
        filters={@filters}
        investigations={@investigations}
      />
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

  # :wake redirects in handle_params, but the render between the two must not
  # crash — a LiveView that raises on a bookmark is a bookmark that does not work.
  defp head(%{scope: %{level: :wake}} = assigns) do
    ~H"""
    <.object_head kind="Ministry" name={@scope.ministry || "…"} sub="waking…" />
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
    <Pages.activity
      scope={@scope}
      events={@events}
      visible={@visible}
      needs={@needs}
      filters={@filters}
      needs_open={@needs_open}
      needs_config_open={@needs_config_open}
      needs_kinds={@needs_kinds}
    />
    """
  end

  defp page(%{scope: %{level: :wake}} = assigns) do
    ~H"""
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
    inbox = for_ministry(assigns.inbox, assigns.ministry)
    published = Ruleset.published(assigns.ministry)
    rules = Ruleset.effective(assigns.ministry)

    assigns =
      assigns
      |> assign(
        inbox: inbox,
        rules: rules,
        published: published,
        draft?: Ruleset.draft?(assigns.ministry),
        version: Ruleset.version(assigns.ministry),
        coverage: Ruleset.coverage(rules),
        diff: Ruleset.diff(published, rules),
        replay: replay(inbox, published, rules)
      )

    ~H"""
    <Pages.ruleset
      scope={@scope}
      ministry={@ministry}
      inbox={@inbox}
      rules={@rules}
      published={@published}
      draft?={@draft?}
      version={@version}
      coverage={@coverage}
      diff={@diff}
      replay={@replay}
      editing_rule={@editing_rule}
    />
    """
  end

  defp page(%{scope: %{level: :registration}} = assigns) do
    ~H"""
    <Pages.registration scope={@scope} ministry={@ministry} editing={editing?(assigns)} />
    """
  end

  @doc false
  # Replays the activations this ministry has actually seen through the draft.
  # A coverage matrix says what COULD change; this says what WOULD have, on the
  # traffic that really arrived — which is the difference between a rule you
  # believe is safe and one you have evidence about.
  def replay(inbox, published, draft) do
    entries =
      inbox
      |> Enum.filter(&(&1[:decision] && &1[:class]))
      |> Enum.map(fn e ->
        class = to_string(e[:class])
        mode = to_string(get_in(e, [:decision, :mode]) || "normal")
        cap = if get_in(e, [:decision, :over_cap]) == true, do: :over, else: :under

        was = Ruleset.decide(published, class, mode, cap)
        would = Ruleset.decide(draft, class, mode, cap)

        %{
          summary: e[:summary] || class,
          class: class,
          mode: mode,
          cap: cap,
          was: was && elem(was, 0),
          would: would && elem(would, 0)
        }
      end)

    %{total: length(entries), changed: Enum.reject(entries, &(&1.was == &1.would))}
  end

  # ==========================================================================
  # Events — every capability the Cabinet Console had
  # ==========================================================================

  # -- reading the log -------------------------------------------------------
  #
  # Every filter change is a patch to a new URL rather than a socket assign, so
  # the view you are looking at is always the view you can send to someone.

  @impl true
  def handle_event("toggle_facet", %{"field" => field, "v" => value}, socket) do
    {:noreply,
     patch_filters(socket, Events.toggle(socket.assigns.filters, facet_field(field), value))}
  end

  def handle_event("clear_facet", %{"field" => field}, socket) do
    {:noreply, patch_filters(socket, Map.put(socket.assigns.filters, facet_field(field), []))}
  end

  def handle_event("set_window", %{"window" => window}, socket) do
    {:noreply, patch_filters(socket, %{socket.assigns.filters | when: window})}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, patch_filters(socket, %{socket.assigns.filters | q: q})}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, patch_filters(socket, Events.blank())}
  end

  def handle_event("set_needs_open", %{"open" => open}, socket) do
    {:noreply, assign(socket, needs_open: open == true or open == "true")}
  end

  def handle_event("toggle_needs_config", _params, socket) do
    {:noreply, assign(socket, needs_config_open: !socket.assigns.needs_config_open)}
  end

  def handle_event("toggle_needs_kind", %{"kind" => kind}, socket) do
    Prefs.toggle_needs_kind(kind)
    {:noreply, load(socket)}
  end

  def handle_event("save_investigation", _params, socket) do
    name = default_investigation_name(socket.assigns.filters)

    case Prefs.save_investigation(name, Events.to_query(socket.assigns.filters)) do
      {:ok, inv} ->
        {:noreply, socket |> put_flash(:info, "Saved as “#{inv.name}”.") |> load()}

      {:error, :blank_name} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Filter the log first — an investigation is a question, not everything."
         )}

      {:error, :duplicate_name} ->
        {:noreply, put_flash(socket, :error, "There is already an investigation called that.")}

      other ->
        {:noreply, put_flash(socket, :error, "Not saved: #{describe(other)}")}
    end
  end

  def handle_event("delete_investigation", %{"id" => id}, socket) do
    Prefs.delete_investigation(id)
    {:noreply, socket |> put_flash(:info, "Forgotten.") |> load()}
  end

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
    # Read the entry before acting: dismissing takes it out of the inbox, and
    # the act has to say which ministry it was about.
    slug = entry_ministry(socket, id)

    case Gate.start_queued(id) do
      :ok ->
        record(socket, "start_queued", id, "ok", slug)

        {:noreply,
         socket |> put_flash(:info, "Starting it — waking the factory and forwarding.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Could not start it: #{describe(other)}")}
    end
  end

  def handle_event("dismiss_entry", %{"id" => id}, socket) do
    slug = entry_ministry(socket, id)

    case Gate.dismiss_queued(id) do
      :ok ->
        record(socket, "dismiss_queued", id, "ok", slug)
        {:noreply, socket |> put_flash(:info, "Dismissed. Nothing was woken.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Could not dismiss it: #{describe(other)}")}
    end
  end

  # -- the rule editor -------------------------------------------------------
  #
  # Every mutation goes through the draft. There is deliberately no path from
  # this LiveView to `:rules`: the only thing that replaces what the Gate reads
  # is `publish`, which will not accept an incomplete ruleset.

  def handle_event("edit_rule", %{"index" => i}, socket) do
    index = String.to_integer(i)

    {:noreply,
     assign(socket, editing_rule: if(socket.assigns.editing_rule == index, do: -1, else: index))}
  end

  def handle_event("toggle_rule", %{"index" => i, "field" => f, "v" => v}, socket) do
    edit(socket, &Ruleset.toggle(&1, String.to_integer(i), field(f), v))
  end

  def handle_event("clear_rule_field", %{"index" => i, "field" => f}, socket) do
    edit(socket, &Ruleset.put(&1, String.to_integer(i), field(f), []))
  end

  def handle_event("set_rule", %{"index" => i, "field" => "cap", "v" => v}, socket) do
    edit(socket, &Ruleset.put(&1, String.to_integer(i), :cap, cap(v)))
  end

  def handle_event("set_rule", %{"index" => i, "field" => "action", "v" => v}, socket) do
    edit(socket, &Ruleset.put(&1, String.to_integer(i), :action, v))
  end

  def handle_event("move_rule", %{"from" => from, "to" => to}, socket) do
    edit(socket, &Ruleset.move(&1, String.to_integer(from), String.to_integer(to)))
  end

  # Drag is the primary way to reorder, but a grip that only responds to a
  # mouse is a control half the operators cannot use.
  def handle_event("reorder_key", %{"key" => key, "index" => i}, socket)
      when key in ["ArrowUp", "ArrowDown"] do
    index = String.to_integer(i)
    to = if key == "ArrowUp", do: index - 1, else: index + 1
    edit(socket, &Ruleset.move(&1, index, to))
  end

  def handle_event("reorder_key", _params, socket), do: {:noreply, socket}

  def handle_event("add_rule", _params, socket) do
    rules = current_rules(socket)
    at = max(length(rules) - 1, 0)
    socket = assign(socket, editing_rule: at)
    edit(socket, &Ruleset.insert(&1, at))
  end

  def handle_event("duplicate_rule", %{"index" => i}, socket) do
    edit(socket, &Ruleset.duplicate(&1, String.to_integer(i)))
  end

  def handle_event("delete_rule", %{"index" => i}, socket) do
    socket = assign(socket, editing_rule: -1)
    edit(socket, &Ruleset.delete(&1, String.to_integer(i)))
  end

  def handle_event("trace", %{"class" => c, "mode" => m, "cap" => cap}, socket) do
    rules = current_rules(socket)

    message =
      case Ruleset.decide(rules, c, m, cap(cap)) do
        {action, n} -> "#{c} · #{m} · #{cap} cap → #{action}, decided by rule #{n}."
        nil -> "#{c} · #{m} · #{cap} cap matches no rule — the Cabinet would queue it."
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("discard_draft", _params, socket) do
    with %{} = m <- socket.assigns.ministry, {:ok, _} <- Ruleset.discard(m.id) do
      record(socket, "ruleset.discard", m.slug, "ok")

      {:noreply,
       socket
       |> assign(editing_rule: -1)
       |> put_flash(:info, "Draft discarded. Nothing changed.")
       |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not discard the draft.")}
    end
  end

  def handle_event("publish", _params, socket) do
    m = socket.assigns.ministry

    case Ruleset.publish(m.id, socket.assigns.actor) do
      {:ok, published} ->
        record(socket, "ruleset.publish", m.slug, "v#{published.rules_version}")

        {:noreply,
         socket
         |> assign(editing_rule: -1)
         |> put_flash(
           :info,
           "Published v#{published.rules_version}. The Cabinet is running it now."
         )
         |> load()}

      {:error, {:undecided, n}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{n} combinations are still undecided — the ruleset has to cover everything."
         )}

      other ->
        {:noreply, put_flash(socket, :error, "Not published: #{describe(other)}")}
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

  # One path for every rule edit: read what the editor is showing, apply the
  # change, save it as a draft. The draft is the only thing that moves.
  defp edit(socket, fun) do
    m = socket.assigns.ministry
    rules = fun.(current_rules(socket))

    case Ruleset.save_draft(m.id, rules) do
      {:ok, _} ->
        {:noreply, load(socket)}

      other ->
        {:noreply, put_flash(socket, :error, "Could not save the draft: #{describe(other)}")}
    end
  end

  defp current_rules(%{assigns: %{ministry: m}}), do: Ruleset.effective(m)

  defp patch_filters(socket, filters) do
    push_patch(socket,
      to: Scope.path(socket.assigns.scope, :activity) <> Events.to_query(filters)
    )
  end

  defp facet_field("kind"), do: :kind
  defp facet_field("ministry"), do: :ministry
  defp facet_field("actor"), do: :actor
  defp facet_field("result"), do: :result

  # The name describes what is being asked, from the filters themselves. An
  # unfiltered log is not a question, so it does not get a name.
  defp default_investigation_name(filters) do
    parts =
      [
        filters.q != "" && "“#{filters.q}”",
        filters.kind != [] &&
          Enum.map_join(filters.kind, ", ", &Events.kind_label/1),
        filters.ministry != [] && Enum.join(filters.ministry, ", "),
        filters.actor != [] && "by #{Enum.join(filters.actor, ", ")}",
        filters.result != [] && Enum.join(filters.result, ", ")
      ]
      |> Enum.filter(&is_binary/1)

    case parts do
      [] -> ""
      list -> Enum.join(list, " · ")
    end
  end

  defp field("class"), do: :class
  defp field("mode"), do: :mode

  defp cap("over"), do: :over
  defp cap("under"), do: :under
  defp cap(_), do: :any

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

  defp entry_ministry(socket, id) do
    case Enum.find(socket.assigns.inbox, &(&1.id == id)) do
      %{ministry_slug: slug} -> slug
      _ -> nil
    end
  end

  defp record(socket, action, target, result, ministry \\ nil),
    do: Activity.record(socket.assigns.actor, action, target, result, ministry)

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

  # An investigation is a name and a query string; the path is built here so
  # the rail links straight to the filtered view.
  defp saved_investigations(scope) do
    Enum.map(Prefs.investigations(), fn inv ->
      %{id: inv.id, name: inv.name, path: Scope.path(scope, :activity) <> (inv[:query] || "")}
    end)
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
