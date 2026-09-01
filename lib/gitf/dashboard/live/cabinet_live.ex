defmodule GiTF.Dashboard.CabinetLive do
  @moduledoc """
  The Cabinet Console — the Cabinet's entire operator surface, served at
  `/` in cabinet mode by `GiTF.Web.CabinetRouter` under its own chrome
  (`GiTF.Dashboard.CabinetLayouts`), never the factory dashboard's.

  Frame (GiTF Control Surface plan §07, operator-chosen): dark icon rail
  on the left, workspace in the middle, contextual inspector on the
  right. Views: Overview · Inbox · Systems · Registry · Policy.
  Selecting a ministry or an activation fills the inspector — the
  why-chain reads the decision provenance the Gate records on every
  inbox entry (rule row, mode, cap state). Every operator act lands in
  the activity feed with the real actor.
  """
  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import Phoenix.HTML, only: [raw: 1]

  alias GiTF.Cabinet.{Activity, Fleet, Gate, Registry, Snapshot}

  @refresh :timer.seconds(20)

  @views ~w(overview inbox systems registry policy)
  @ifilters ~w(waiting woke dropped all)

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh)

    {:ok,
     socket
     |> assign(:page_title, "Cabinet")
     |> assign(:actor, (is_map(session) && session["tailnet_login"]) || "operator")
     |> assign(:view, "overview")
     |> assign(:sel, nil)
     |> assign(:itab, "overview")
     |> assign(:ifilter, "waiting")
     |> assign(:editing, nil)
     |> init_toasts()
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh)
    {:noreply, load(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("view", %{"view" => view}, socket) when view in @views do
    {:noreply, assign(socket, :view, view)}
  end

  def handle_event("select", %{"type" => type, "id" => id}, socket) do
    {:noreply, socket |> assign(:sel, {type, id}) |> assign(:itab, "overview")}
  end

  def handle_event("itab", %{"tab" => tab}, socket) when tab in ~w(overview why raw) do
    {:noreply, assign(socket, :itab, tab)}
  end

  def handle_event("ifilter", %{"filter" => f}, socket) when f in @ifilters do
    {:noreply, assign(socket, :ifilter, f)}
  end

  def handle_event("wake", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.wake(ministry) do
      Activity.record(socket.assigns.actor, "wake", ministry.slug, "starting")

      {:noreply,
       socket |> put_flash(:info, "Waking #{ministry.slug} — healthy in ~60–90s.") |> load()}
    else
      other ->
        {:noreply, put_flash(socket, :error, "Wake failed: #{inspect(other)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.stop(ministry) do
      Activity.record(socket.assigns.actor, "stop", ministry.slug, "stopping")
      {:noreply, socket |> put_flash(:info, "Stopping #{ministry.slug}.") |> load()}
    else
      other ->
        {:noreply, put_flash(socket, :error, "Stop failed: #{inspect(other)}")}
    end
  end

  def handle_event("set_mode", %{"id" => id, "mode" => mode}, socket) do
    case Registry.set_mode(id, mode) do
      {:ok, m} ->
        Activity.record(socket.assigns.actor, "mode", m.slug, mode)
        {:noreply, socket |> put_flash(:info, "#{m.slug} is now in #{mode} mode.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Mode change failed: #{inspect(other)}")}
    end
  end

  def handle_event("start_entry", %{"id" => id}, socket) do
    case Gate.start_queued(id) do
      :ok ->
        entry = Enum.find(socket.assigns.inbox, &(&1.id == id))
        Activity.record(socket.assigns.actor, "start", (entry && entry.summary) || id, "waking")
        {:noreply, socket |> put_flash(:info, "Waking the factory and forwarding.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Start failed: #{inspect(other)}")}
    end
  end

  def handle_event("snapshot", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id) do
      case Snapshot.refresh(ministry) do
        :ok ->
          {:noreply, socket |> put_flash(:info, "Snapshot refreshed from the factory.") |> load()}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Snapshot needs a running, reachable factory (#{inspect(reason)})."
           )}
      end
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, id)}
  end

  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, :editing, :new)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("save_ministry", %{"ministry_id" => id} = params, socket) when id != "" do
    case Registry.edit(id, params) do
      {:ok, m} ->
        Activity.record(socket.assigns.actor, "edit", m.slug, "registry updated")

        {:noreply,
         socket |> assign(:editing, nil) |> put_flash(:info, "#{m.slug} updated.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Edit failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_ministry", params, socket) do
    case Registry.create(params) do
      {:ok, m} ->
        Activity.record(socket.assigns.actor, "register", m.slug, "ministry registered")

        {:noreply,
         socket |> assign(:editing, nil) |> put_flash(:info, "#{m.slug} registered.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Register failed: #{inspect(reason)}")}
    end
  end

  # One document, two views — clicking a cell in the Policy grid cycles
  # its action (wake → queue → drop → wake) and writes the JDM back. The
  # failure direction stays queue: an edit that can't be applied changes
  # nothing.
  def handle_event("cycle_rule", %{"id" => id, "rule" => rule_n}, socket) do
    with %{} = ministry <- Registry.get(id),
         {n, ""} <- Integer.parse(rule_n),
         {:ok, updated_doc} <- cycle_rule_action(ministry, n),
         {:ok, m} <- Registry.update(id, &Map.put(&1, :rules, updated_doc)) do
      row = Enum.find(policy_rows(m), &(&1.n == n))
      Activity.record(socket.assigns.actor, "rule", "#{m.slug} rule #{n}", row && row.action)

      {:noreply,
       socket |> put_flash(:info, "Rule #{n}: #{row && row.action} — first hit wins.") |> load()}
    else
      other ->
        {:noreply, put_flash(socket, :error, "Rule edit failed: #{inspect(other)}")}
    end
  end

  defp load(socket) do
    ministries =
      Enum.map(Registry.list(), fn m ->
        Map.put(m, :box_state, Fleet.instance_state(m))
      end)

    socket
    |> assign(:ministries, ministries)
    |> assign(:inbox, Enum.take(Gate.inbox(), 50))
    |> assign(:activity, Activity.list(20))
  end

  # -- selection ---------------------------------------------------------------

  defp selected(%{sel: {"ministry", id}, ministries: ms}), do: {:ministry, find_by_id(ms, id)}
  defp selected(%{sel: {"entry", id}, inbox: inbox}), do: {:entry, find_by_id(inbox, id)}
  defp selected(_), do: nil

  defp find_by_id(list, id), do: Enum.find(list, &(&1.id == id))

  # -- helpers -----------------------------------------------------------------

  defp running?(m), do: m[:box_state] == "running"

  defp state_pill(m) do
    case m[:box_state] do
      "running" -> {"ok", "Running"}
      "pending" -> {"recon", "Waking"}
      "stopping" -> {"recon", "Stopping"}
      "stopped" -> {"off", "Stopped"}
      nil -> {"off", "No factory"}
      other -> {"off", to_string(other)}
    end
  end

  defp queued(inbox, slug \\ nil) do
    Enum.filter(inbox, &(&1.status == "queued" and (slug == nil or &1.ministry_slug == slug)))
  end

  defp filtered_inbox(inbox, "waiting"), do: Enum.filter(inbox, &(&1.status == "queued"))

  defp filtered_inbox(inbox, "woke"),
    do: Enum.filter(inbox, &(&1.status in ["waking", "forwarded", "forward_failed"]))

  defp filtered_inbox(inbox, "dropped"), do: Enum.filter(inbox, &(&1.status == "dropped"))
  defp filtered_inbox(inbox, _all), do: inbox

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp hhmm(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%MZ")
  defp hhmm(_), do: "—"

  defp money(nil), do: "—"
  defp money(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  defp money(str) when is_binary(str) do
    case Float.parse(str) do
      {n, _} -> money(n)
      :error -> "—"
    end
  end

  defp spend_line(m) do
    case m[:spend_usd] do
      nil -> "no snapshot yet"
      n -> "#{money(n)} recent · snap #{hhmm(m[:spend_at])}"
    end
  end

  # The why-chain, straight from the Gate's recorded provenance.
  defp why(%{decision: %{} = d} = entry) do
    rule =
      case d[:rule] do
        nil -> "no rule matched (#{d[:fallback] || "ruleset failure"}) — queued by doctrine"
        n -> "ruleset rule #{n} of #{d[:rule_count]}"
      end

    action = d[:action] || entry.status
    mode = d[:mode] || "?"

    cap =
      cond do
        d[:over_cap] -> "over the monthly cap — wakes become queues"
        action == "wake" -> "under the monthly cap"
        true -> "not consulted (no wake)"
      end

    %{rule: rule, action: action, mode: mode, cap: cap, decided_at: d[:decided_at]}
  end

  defp why(_entry), do: nil

  defp reason_sentence(%{class: "feature"}, %{action: "queue"}),
    do: "Features wait for you — only bugs and PR reviews wake a factory on their own."

  defp reason_sentence(%{class: "bug"}, %{action: "queue", mode: "off"}),
    do: "A bug would normally wake the factory, but the ministry was off when this arrived."

  defp reason_sentence(_, %{action: "queue"}),
    do: "Queued for you — the ruleset (or its failure doctrine) decided not to wake anything."

  defp reason_sentence(_, %{action: "wake"}),
    do: "Worked immediately — the factory was woken and the delivery forwarded verbatim."

  defp reason_sentence(_, _), do: nil

  # Renders the ministry's JDM decision table as one row per rule.
  # One document, two views: this grid and the Raw tab (Tailscale's ACL
  # editor pattern). Unknown constructs simply don't render here — the
  # raw view is always the truth.
  defp policy_columns(ministry) do
    doc = ministry[:rules] || GiTF.Cabinet.JDM.default_rules()

    with %{"nodes" => nodes} <- doc,
         %{"content" => %{"inputs" => inputs}} <-
           Enum.find(nodes, &(&1["type"] == "decisionTableNode")) do
      Enum.map(inputs, &(&1["name"] || &1["field"]))
    else
      _ -> []
    end
  end

  defp policy_rows(ministry) do
    doc = ministry[:rules] || GiTF.Cabinet.JDM.default_rules()

    with %{"nodes" => nodes} <- doc,
         %{"content" => %{"rules" => rules, "inputs" => inputs, "outputs" => [out | _]}} <-
           Enum.find(nodes, &(&1["type"] == "decisionTableNode")) do
      for {rule, idx} <- Enum.with_index(rules, 1) do
        %{
          n: idx,
          cells: Enum.map(inputs, fn i -> unquote_cell(rule[i["id"]]) end),
          action: unquote_cell(rule[out["id"]])
        }
      end
    else
      _ -> []
    end
  end

  @action_cycle %{"wake" => "queue", "queue" => "drop", "drop" => "wake"}

  defp cycle_rule_action(ministry, n) do
    doc = ministry[:rules] || GiTF.Cabinet.JDM.default_rules()

    with %{"nodes" => nodes} <- doc,
         node_idx when is_integer(node_idx) <-
           Enum.find_index(nodes, &(&1["type"] == "decisionTableNode")),
         %{"content" => %{"rules" => rules, "outputs" => [out | _]}} <- Enum.at(nodes, node_idx),
         rule when is_map(rule) <- Enum.at(rules, n - 1) do
      current = rule[out["id"]] |> to_string() |> String.trim("\"")
      next = Map.get(@action_cycle, current, "queue")
      new_rule = Map.put(rule, out["id"], ~s("#{next}"))
      new_rules = List.replace_at(rules, n - 1, new_rule)

      new_doc =
        update_in(doc, ["nodes"], fn ns ->
          List.update_at(ns, node_idx, fn node ->
            put_in(node, ["content", "rules"], new_rules)
          end)
        end)

      if GiTF.Cabinet.JDM.supported?(new_doc), do: {:ok, new_doc}, else: {:error, :unsupported}
    else
      _ -> {:error, :no_such_rule}
    end
  end

  defp unquote_cell(nil), do: "any"
  defp unquote_cell(""), do: "any"

  # A JDM cell is a literal (`"bug"`, `false`) or an "in" list
  # (`"normal", "vacation"`) — render lists as a · b.
  defp unquote_cell(v) when is_binary(v) do
    v
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    |> Enum.join(" · ")
  end

  defp unquote_cell(v), do: to_string(v)

  defp raw_json(term) do
    term
    |> scrub()
    |> Jason.encode!(pretty: true)
  rescue
    _ -> inspect(term, pretty: true)
  end

  defp scrub(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp scrub(%{} = map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(v), do: v

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:selection, selected(assigns))
      |> assign(:waiting, queued(assigns.inbox))

    ~H"""
    <div class="console">
      <nav class="rail">
        <div class="logo">
          <svg class="ico" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="3" /><path d="M8 9h8M8 15h8" /></svg>
        </div>
        <button :for={{view, label, icon} <- rail_items()} class={@view == view && "on"} phx-click="view" phx-value-view={view}>
          <span class="badge-anchor">
            {raw(icon)}
            <span :if={view == "inbox" and @waiting != []} class="count">{length(@waiting)}</span>
          </span>
          {label}
        </button>
        <div class="spacer"></div>
      </nav>

      <main class="workspace">
        <div class="crumbs"><b>Cabinet</b><span>·</span><span>{length(@ministries)} ministries</span><span>·</span><span>{@actor}</span></div>

        <%= case @view do %>
          <% "overview" -> %>
            <div class="tiles">
              <div class="tile">
                <span class="k">Factories</span>
                <span class="v"><span class={"pill #{if Enum.any?(@ministries, &running?/1), do: "ok", else: "off"}"}><span class="dot"></span>{Enum.count(@ministries, &running?/1)} running</span></span>
                <span class="s">{Enum.count(@ministries, &(!running?(&1)))} stopped</span>
              </div>
              <div class="tile">
                <span class="k">Waiting on you</span>
                <span class="v mono">{length(@waiting)}</span>
                <span class="s">queued activations</span>
              </div>
              <div class="tile">
                <span class="k">Ministries</span>
                <span class="v mono">{length(@ministries)}</span>
                <span class="s">{@ministries |> Enum.map(& &1.slug) |> Enum.join(" · ")}</span>
              </div>
            </div>

            <div class="panel">
              <div class="panel-head"><h2>Ministries</h2><button class="end" phx-click="view" phx-value-view="registry">Registry</button></div>
              <div :if={@ministries == []} class="empty">No ministries registered yet — Registry → Register a ministry.</div>
              <button :for={m <- @ministries} class={["mrow", match?({"ministry", id} when id == m.id, @sel) && "sel"]} phx-click="select" phx-value-type="ministry" phx-value-id={m.id}>
                <span class="who">
                  <span class={["avatar", !running?(m) && "dim"]}>{initials(m.name)}</span>
                  <span>
                    <div class="nm">{m.name}</div>
                    <div class="sub">{m.slug}</div>
                  </span>
                </span>
                <.state_badge ministry={m} />
                <span class="stat"><span class="k">Mode</span><span class="v"><b>{m.mode}</b></span></span>
                <span class="stat"><span class="k">Spend</span><span class="v"><b>{money(m[:spend_usd])}</b> · cap {money(m[:cost_cap_usd])}</span></span>
                <span class="stat"><span class="k">Waiting</span><span class="v"><b>{length(queued(@inbox, m.slug))}</b></span></span>
              </button>
            </div>

            <div class="panel">
              <div class="panel-head"><h2>Waiting on you</h2><button class="end" phx-click="view" phx-value-view="inbox">Open inbox</button></div>
              <div :if={@waiting == []} class="empty">Nothing waiting on you.</div>
              <.inbox_row :for={e <- Enum.take(@waiting, 5)} entry={e} sel={@sel} show_start={true} />
            </div>

            <div class="panel">
              <div class="panel-head"><h2>Activity</h2></div>
              <div :if={@activity == []} class="empty">Nothing yet — wakes, stops, mode changes and starts land here.</div>
              <div :for={a <- @activity} class="irow" style="grid-template-columns:64px minmax(0,1fr) auto">
                <span class="when">{hhmm(a.at)}</span>
                <span><b>{a.actor}</b> · {a.action} <span class="mono">{a.target}</span></span>
                <span class="muted" style="font-size:12.5px">{a.result}</span>
              </div>
            </div>

          <% "inbox" -> %>
            <div class="view-head">
              <h1>Inbox</h1>
              <span class="sub">activations — what the Cabinet decided, and what waits for you</span>
              <span class="seg end">
                <button :for={f <- ["waiting", "woke", "dropped", "all"]} class={@ifilter == f && "on"} phx-click="ifilter" phx-value-filter={f}>{f}</button>
              </span>
            </div>
            <div class="panel">
              <% shown = filtered_inbox(@inbox, @ifilter) %>
              <div :if={shown == []} class="empty">Nothing here under "{@ifilter}".</div>
              <.inbox_row :for={e <- shown} entry={e} sel={@sel} show_start={e.status == "queued"} />
            </div>

          <% "systems" -> %>
            <div class="view-head"><h1>Systems</h1><span class="sub">the Cabinet as it is wired — health on every node</span></div>
            <div class="systree">
              <div class="sysnode">
                <span class="sysicon"><svg class="ico" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="3" /><path d="M8 9h8M8 15h8" /></svg></span>
                <span class="nm"><span class="ty">Cabinet</span>this node</span>
                <span class="kv">release <b>{GiTF.version()}</b></span>
                <span class="kv">ingress <b>/hooks/&lt;slug&gt;</b></span>
                <span class="kv">{length(@inbox)} activations recorded</span>
              </div>
              <%= for m <- @ministries do %>
                <button class="sysnode indent-1" phx-click="select" phx-value-type="ministry" phx-value-id={m.id}>
                  <span class="sysicon"><svg class="ico" viewBox="0 0 24 24"><path d="M12 3.5 20 7v5.5c0 4.5-3.2 7.3-8 8.5-4.8-1.2-8-4-8-8.5V7z" /></svg></span>
                  <span class="nm"><span class="ty">Ministry</span>{m.name}</span>
                  <span class="kv">mode <b>{m.mode}</b> · cap <b>{money(m[:cost_cap_usd])}</b></span>
                  <span class="kv"><.state_badge ministry={m} /></span>
                  <span class="kv">waiting <b>{length(queued(@inbox, m.slug))}</b></span>
                </button>
                <div class="sysnode indent-2">
                  <span class="sysicon"><svg class="ico" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="6.5" rx="1.5" /><rect x="4" y="13.5" width="16" height="6.5" rx="1.5" /><path d="M7.2 7.2h.01M7.2 16.7h.01" /></svg></span>
                  <span class="nm"><span class="ty">Factory</span>{m[:instance_id] || "not provisioned"}</span>
                  <span class="kv">{if m.url, do: m.url, else: "no url"}</span>
                  <span class="kv"><b>{m[:box_state] || "—"}</b>{if m[:health], do: " · health #{m.health}"}</span>
                  <span class="kv">{spend_line(m)}</span>
                </div>
              <% end %>
            </div>

          <% "registry" -> %>
            <div class="view-head">
              <h1>Registry</h1>
              <span class="sub">ministries as configuration objects — secrets by NAME only</span>
              <button class="btn pri sm end" phx-click="edit">Register a ministry</button>
            </div>

            <div :if={@editing == :new} class="panel">
              <div class="panel-head"><h2>Register a ministry</h2></div>
              <form phx-submit="save_ministry">
                <div class="formgrid">
                  <div class="field"><label>slug</label><input name="slug" placeholder="home-affairs" required /></div>
                  <div class="field"><label>name</label><input name="name" placeholder="Home Affairs" /></div>
                  <div class="field"><label>factory url</label><input name="url" placeholder="https://factory.ghostinthefactory.com" /></div>
                  <div class="field"><label>factory instance id</label><input name="instance_id" placeholder="i-…" /></div>
                  <div class="field"><label>webhook secret env</label><input name="webhook_secret_env" placeholder="GITF_MIN_…_WEBHOOK_SECRET" /></div>
                  <div class="field"><label>api key env</label><input name="api_key_env" placeholder="GITF_MIN_…_API_KEY" /></div>
                  <div class="field"><label>cost cap $/month</label><input name="cost_cap_usd" placeholder="100" /></div>
                </div>
                <div class="formfoot">
                  <button type="button" class="btn sm" phx-click="cancel_edit">Cancel</button>
                  <button type="submit" class="btn pri sm">Register</button>
                </div>
              </form>
            </div>

            <div :for={m <- @ministries} class="panel">
              <div class="panel-head">
                <h2>{m.name}</h2>
                <button :if={@editing != m.id} class="end" phx-click="edit" phx-value-id={m.id}>Edit</button>
              </div>
              <div :if={@editing != m.id} style="padding:6px 20px 18px">
                <dl class="kv" style="border:0">
                  <dt>slug</dt><dd class="mono">{m.slug}</dd>
                  <dt>factory</dt><dd class="mono">{m[:instance_id] || "not provisioned"}</dd>
                  <dt>url</dt><dd>{m.url || "—"}</dd>
                  <dt>secrets</dt><dd class="mono" style="font-size:12px">{m[:webhook_secret_env] || "—"} · {m[:api_key_env] || "—"}</dd>
                  <dt>cost cap</dt><dd>{money(m[:cost_cap_usd])} / month</dd>
                  <dt>spend</dt><dd>{spend_line(m)}</dd>
                  <dt>mode</dt><dd>{m.mode}</dd>
                </dl>
              </div>
              <form :if={@editing == m.id} phx-submit="save_ministry">
                <input type="hidden" name="ministry_id" value={m.id} />
                <div class="formgrid">
                  <div class="field"><label>name</label><input name="name" value={m.name} /></div>
                  <div class="field"><label>factory url</label><input name="url" value={m.url} /></div>
                  <div class="field"><label>factory instance id</label><input name="instance_id" value={m[:instance_id]} /></div>
                  <div class="field"><label>webhook secret env</label><input name="webhook_secret_env" value={m[:webhook_secret_env]} /></div>
                  <div class="field"><label>api key env</label><input name="api_key_env" value={m[:api_key_env]} /></div>
                  <div class="field"><label>cost cap $/month</label><input name="cost_cap_usd" value={m[:cost_cap_usd]} /></div>
                </div>
                <div class="formfoot">
                  <button type="button" class="btn sm" phx-click="cancel_edit">Cancel</button>
                  <button type="submit" class="btn pri sm">Save</button>
                </div>
              </form>
            </div>

          <% "policy" -> %>
            <div class="view-head"><h1>Policy</h1><span class="sub">activation rulesets — click an action to cycle it; the raw JDM is the same document</span></div>
            <div :for={m <- @ministries} class="panel">
              <div class="panel-head">
                <h2>{m.name}</h2>
                <span class="seg end">
                  <button :for={mode <- ~w(normal vacation off)} class={m.mode == mode && "on"} phx-click="set_mode" phx-value-id={m.id} phx-value-mode={mode}>{mode}</button>
                </span>
              </div>
              <table class="polgrid">
                <tr>
                  <th>#</th>
                  <th :for={col <- policy_columns(m)}>{col}</th>
                  <th>action</th>
                </tr>
                <tr :for={row <- policy_rows(m)}>
                  <td class="mono muted">{row.n}</td>
                  <td :for={cell <- row.cells} class={cell != "any" && "n"}>{cell}</td>
                  <td>
                    <button class="cellbtn" phx-click="cycle_rule" phx-value-id={m.id} phx-value-rule={row.n} title="Click to cycle wake → queue → drop">
                      <span class={"cell #{row.action}"}>{row.action}</span>
                    </button>
                  </td>
                </tr>
              </table>
              <div class="footnote">
                First hit wins. Wakes are gated by the monthly cap; anything the rules can't decide queues — it never wakes.
                Select an inbox entry to see which rule decided it.
              </div>
            </div>
        <% end %>
      </main>

      <aside class="inspector">
        <%= case @selection do %>
          <% {:ministry, %{} = m} -> %>
            <div class="insp-head">
              <div class="ty">Ministry</div>
              <h2>{m.name}</h2>
              <div class="strip">
                <.state_badge ministry={m} />
                <span class={"pill #{if queued(@inbox, m.slug) == [], do: "off", else: "warn"}"}><span class="dot"></span>{length(queued(@inbox, m.slug))} waiting</span>
              </div>
              <div class="insp-actions">
                <span class="seg">
                  <button :for={mode <- ~w(normal vacation off)} class={m.mode == mode && "on"} phx-click="set_mode" phx-value-id={m.id} phx-value-mode={mode}>{mode}</button>
                </span>
                <button :if={!running?(m)} class="btn pri sm" phx-click="wake" phx-value-id={m.id}>Wake factory</button>
                <button :if={running?(m)} class="btn sm" phx-click="stop" phx-value-id={m.id}>Stop factory</button>
                <button :if={running?(m)} class="btn sm" phx-click="snapshot" phx-value-id={m.id}>Refresh snapshot</button>
                <a :if={m.url} class="btn sm" href={m.url} target="_blank">Dashboard ↗</a>
              </div>
            </div>
            <.itab_bar itab={@itab} why_label="Evidence" />
            <div class="ipane">
              <%= case @itab do %>
                <% "overview" -> %>
                  <dl class="kv">
                    <dt>factory</dt><dd class="mono">{m[:instance_id] || "not provisioned"}</dd>
                    <dt>state</dt><dd>{m[:box_state] || "—"}{if m[:health], do: " · health #{m.health}"}</dd>
                    <dt>url</dt><dd>{m.url || "—"}</dd>
                    <dt>spend</dt><dd>{spend_line(m)}</dd>
                    <dt>cost cap</dt><dd>{money(m[:cost_cap_usd])} / month</dd>
                  </dl>
                  <div class="rel">
                    <span><span class="verb">governed by</span>activation ruleset · {length(policy_rows(m))} rules · mode {m.mode}</span>
                    <span><span class="verb">receives</span>POST /hooks/{m.slug}</span>
                  </div>
                  <div class="mini-head">Waiting on you</div>
                  <div :if={queued(@inbox, m.slug) == []} class="muted" style="padding:8px 0">Nothing.</div>
                  <div :for={e <- Enum.take(queued(@inbox, m.slug), 6)} class="factor">
                    <button phx-click="select" phx-value-type="entry" phx-value-id={e.id} style="color:var(--accent);font-weight:500">{e.summary}</button>
                    <span class="v">{hhmm(e.inserted_at)}</span>
                  </div>
                <% "why" -> %>
                  <div class="mini-head">Recent activations</div>
                  <div :for={e <- @inbox |> Enum.filter(&(&1.ministry_slug == m.slug)) |> Enum.take(10)} class="factor">
                    <button phx-click="select" phx-value-type="entry" phx-value-id={e.id} style="color:var(--accent);font-weight:500">{e.class} → {e.status}</button>
                    <span class="v">{hhmm(e.inserted_at)}<span :if={e[:decision][:rule]}> · rule {e.decision.rule}</span></span>
                  </div>
                <% "raw" -> %>
                  <div class="mini-head">Registry entry</div>
                  <pre class="raw">{raw_json(Map.drop(m, [:__struct__]))}</pre>
              <% end %>
            </div>
          <% {:entry, %{} = e} -> %>
            <% w = why(e) %>
            <div class="insp-head">
              <div class="ty">Activation · {e.ministry_slug}</div>
              <h2>{e.summary}</h2>
              <div class="strip">
                <span class={"tag #{e.class}"}>{e.class}</span>
                <.status_pill status={e.status} />
                <span class="muted" style="font-size:12.5px">{hhmm(e.inserted_at)}</span>
              </div>
              <div class="insp-actions">
                <button :if={e.status == "queued"} class="btn pri sm" phx-click="start_entry" phx-value-id={e.id}>Start this</button>
              </div>
            </div>
            <.itab_bar itab={@itab} why_label="Why" />
            <div class="ipane">
              <%= case @itab do %>
                <% tab when tab in ["overview", "why"] -> %>
                  <div :if={w} class="decision">
                    <div class="reason">{reason_sentence(e, w) || "#{e.class} → #{w.action}."}</div>
                    <div class="factor"><span>classified as {e.class}</span><span class="v">{e.event}</span></div>
                    <div class="factor"><span>{w.rule}</span><span class="v">{e.class} · {w.mode} → {w.action}</span></div>
                    <div class="factor"><span>mode {w.mode}</span><span class="v">at {hhmm(w.decided_at)}</span></div>
                    <div class="factor"><span>cost cap</span><span class="v">{w.cap}</span></div>
                  </div>
                  <div :if={!w} class="muted" style="padding:12px 0">
                    Recorded before decision provenance existed — the raw entry is all there is.
                  </div>
                <% "raw" -> %>
                  <div class="mini-head">Inbox entry</div>
                  <pre class="raw">{raw_json(Map.drop(e, [:__struct__]))}</pre>
              <% end %>
            </div>
          <% _ -> %>
            <div class="empty" style="padding:24px">
              Select a ministry or an activation — its state, its evidence, and its raw form appear here.
            </div>
        <% end %>
      </aside>
    </div>
    <div :if={Phoenix.Flash.get(@flash, :info)} class="flash">{Phoenix.Flash.get(@flash, :info)}</div>
    <div :if={Phoenix.Flash.get(@flash, :error)} class="flash err">{Phoenix.Flash.get(@flash, :error)}</div>
    """
  end

  defp state_badge(assigns) do
    {kind, label} = state_pill(assigns.ministry)
    assigns = assign(assigns, kind: kind, label: label)

    ~H"""
    <span class={"pill #{@kind}"}><span class="dot"></span>{@label}</span>
    """
  end

  defp status_pill(assigns) do
    kind =
      case assigns.status do
        "queued" -> "warn"
        "waking" -> "recon"
        "forwarded" -> "ok"
        "forward_failed" -> "crit"
        _ -> "off"
      end

    assigns = assign(assigns, :kind, kind)

    ~H"""
    <span class={"pill #{@kind}"}><span class="dot"></span>{@status}</span>
    """
  end

  defp inbox_row(assigns) do
    ~H"""
    <button class={["irow", match?({"entry", id} when id == @entry.id, @sel) && "sel"]} phx-click="select" phx-value-type="entry" phx-value-id={@entry.id}>
      <span class={"tag #{@entry.class}"}>{@entry.class}</span>
      <span style="min-width:0">
        <div class="t1">{@entry.summary}</div>
        <div class="t2">
          <em>{@entry.class}</em> under <em>{@entry[:decision][:mode] || "?"}</em>
          → {@entry[:decision][:action] || @entry.status}<span :if={@entry[:decision][:rule]}> · rule {@entry.decision.rule}</span>
          · {@entry.ministry_slug}
        </div>
      </span>
      <span class="when">{hhmm(@entry.inserted_at)}</span>
      <span :if={@show_start} class="btn pri sm" phx-click="start_entry" phx-value-id={@entry.id}>Start this</span>
      <span :if={!@show_start}><.status_pill status={@entry.status} /></span>
    </button>
    """
  end

  defp itab_bar(assigns) do
    ~H"""
    <div class="itabs">
      <button class={@itab == "overview" && "on"} phx-click="itab" phx-value-tab="overview">Overview</button>
      <button class={@itab == "why" && "on"} phx-click="itab" phx-value-tab="why">{@why_label}</button>
      <button class={@itab == "raw" && "on"} phx-click="itab" phx-value-tab="raw">Raw</button>
    </div>
    """
  end

  defp rail_items do
    [
      {"overview", "Overview",
       ~s(<svg class="ico" viewBox="0 0 24 24"><rect x="3.5" y="3.5" width="7.5" height="7.5" rx="2"/><rect x="13" y="3.5" width="7.5" height="7.5" rx="2"/><rect x="3.5" y="13" width="7.5" height="7.5" rx="2"/><rect x="13" y="13" width="7.5" height="7.5" rx="2"/></svg>)},
      {"inbox", "Inbox",
       ~s(<svg class="ico" viewBox="0 0 24 24"><path d="M3.5 13.5 6 5.5h12l2.5 8"/><path d="M3.5 13.5V18a1.5 1.5 0 0 0 1.5 1.5h14a1.5 1.5 0 0 0 1.5-1.5v-4.5h-5a3.5 3.5 0 0 1-7 0h-5z"/></svg>)},
      {"systems", "Systems",
       ~s(<svg class="ico" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="16" height="6.5" rx="1.5"/><path d="M7.2 7.2h.01M7.2 16.7h.01"/></svg>)},
      {"registry", "Registry",
       ~s(<svg class="ico" viewBox="0 0 24 24"><path d="M4 7.5A1.5 1.5 0 0 1 5.5 6h4l2 2.5h7A1.5 1.5 0 0 1 20 10v7.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z"/></svg>)},
      {"policy", "Policy",
       ~s(<svg class="ico" viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2.2"/><circle cx="8" cy="17" r="2.2"/></svg>)}
    ]
  end
end
