defmodule GiTF.Dashboard.CabinetLive do
  @moduledoc """
  The Cabinet Console — the fleet's entire operator surface, served at
  `/` in cabinet mode by `GiTF.Web.CabinetRouter` under its own chrome
  (`GiTF.Dashboard.CabinetLayouts`), never the factory dashboard's.

  Frame (GiTF Control Surface plan §07, operator-chosen): dark icon rail
  on the left, workspace in the middle, contextual inspector on the
  right. Views: Overview · Inbox · Systems · Registry · Policy. Selecting
  a ministry or an activation fills the inspector with
  Overview / Why / Raw — the why-chain reads the decision provenance the
  Gate records on every inbox entry (rule row, mode, cap state).
  """
  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import Phoenix.HTML, only: [raw: 1]

  alias GiTF.Cabinet.{Fleet, Gate, Registry}

  @refresh :timer.seconds(20)

  @views ~w(overview inbox systems registry policy)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh)

    {:ok,
     socket
     |> assign(:page_title, "Cabinet")
     |> assign(:view, "overview")
     |> assign(:sel, nil)
     |> assign(:itab, "overview")
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

  def handle_event("wake", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.wake(ministry) do
      {:noreply,
       socket |> put_flash(:info, "Waking #{ministry.slug} — healthy in ~60–90s.") |> load()}
    else
      other ->
        {:noreply, put_flash(socket, :error, "Wake failed: #{inspect(other)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.stop(ministry) do
      {:noreply, socket |> put_flash(:info, "Stopping #{ministry.slug}.") |> load()}
    else
      other ->
        {:noreply, put_flash(socket, :error, "Stop failed: #{inspect(other)}")}
    end
  end

  def handle_event("set_mode", %{"id" => id, "mode" => mode}, socket) do
    case Registry.set_mode(id, mode) do
      {:ok, m} ->
        {:noreply, socket |> put_flash(:info, "#{m.slug} is now in #{mode} mode.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Mode change failed: #{inspect(other)}")}
    end
  end

  def handle_event("start_entry", %{"id" => id}, socket) do
    case Gate.start_queued(id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Waking the factory and forwarding.") |> load()}

      other ->
        {:noreply, put_flash(socket, :error, "Start failed: #{inspect(other)}")}
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
  end

  # -- selection ---------------------------------------------------------------

  defp selected(%{sel: {"ministry", id}, ministries: ms}), do: {:ministry, find_by_id(ms, id)}
  defp selected(%{sel: {"entry", id}, inbox: inbox}), do: {:entry, find_by_id(inbox, id)}
  defp selected(_), do: nil

  defp find_by_id(list, id), do: Enum.find(list, &(&1.id == id))

  # -- vocabulary helpers ------------------------------------------------------

  defp running?(m), do: m[:box_state] == "running"

  defp state_pill(m) do
    case m[:box_state] do
      "running" -> {"ok", "Running"}
      "pending" -> {"recon", "Waking"}
      "stopping" -> {"recon", "Stopping"}
      "stopped" -> {"off", "Stopped"}
      nil -> {"off", "No factory"}
      other -> {"off", other}
    end
  end

  defp queued(inbox, slug \\ nil) do
    Enum.filter(inbox, &(&1.status == "queued" and (slug == nil or &1.ministry_slug == slug)))
  end

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

  # Renders the ministry's JDM decision table as class-per-row cells.
  # One document, two views: this grid and the Raw tab (Tailscale's ACL
  # editor pattern). Unknown constructs simply don't render here — the
  # raw view is always the truth.
  defp policy_rows(ministry) do
    doc = ministry[:rules] || GiTF.Cabinet.JDM.default_rules()

    with %{"nodes" => nodes} <- doc,
         %{"content" => %{"rules" => rules, "inputs" => inputs, "outputs" => [out | _]}} <-
           Enum.find(nodes, &(&1["type"] == "decisionTableNode")) do
      class_id = Enum.find_value(inputs, &(&1["field"] == "class" && &1["id"]))
      mode_id = Enum.find_value(inputs, &(&1["field"] == "mode" && &1["id"]))

      for {rule, idx} <- Enum.with_index(rules, 1) do
        %{
          n: idx,
          class: unquote_cell(rule[class_id]),
          mode: unquote_cell(rule[mode_id]),
          action: unquote_cell(rule[out["id"]])
        }
      end
    else
      _ -> []
    end
  end

  defp unquote_cell(nil), do: "any"
  defp unquote_cell(""), do: "any"
  defp unquote_cell(v) when is_binary(v), do: String.trim(v, "\"")
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
        <div class="crumbs"><b>Fleet</b><span>·</span><span>{length(@ministries)} ministries</span></div>

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
              <div class="panel-head"><h2>Ministries</h2></div>
              <div :if={@ministries == []} class="empty">No ministries registered — use the register_ministry tool.</div>
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
                <span class="stat"><span class="k">Cap</span><span class="v"><b>{money(m[:cost_cap_usd])}</b> / month</span></span>
                <span class="stat"><span class="k">Waiting</span><span class="v"><b>{length(queued(@inbox, m.slug))}</b></span></span>
              </button>
            </div>

            <div class="panel">
              <div class="panel-head"><h2>Waiting on you</h2><button class="end" phx-click="view" phx-value-view="inbox">Open inbox</button></div>
              <div :if={@waiting == []} class="empty">Nothing waiting on you.</div>
              <.inbox_row :for={e <- Enum.take(@waiting, 5)} entry={e} sel={@sel} show_start={true} />
            </div>

          <% "inbox" -> %>
            <div class="view-head"><h1>Inbox</h1><span class="sub">activations — what the Cabinet decided, and what waits for you</span></div>
            <div class="panel">
              <div :if={@inbox == []} class="empty">No activations yet — deliveries land here.</div>
              <.inbox_row :for={e <- @inbox} entry={e} sel={@sel} show_start={e.status == "queued"} />
            </div>

          <% "systems" -> %>
            <div class="view-head"><h1>Systems</h1><span class="sub">the fleet as it is wired — health on every node</span></div>
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
                  <span class="kv"><b>{m[:box_state] || "—"}</b></span>
                  <span class="kv"></span>
                </div>
              <% end %>
            </div>

          <% "registry" -> %>
            <div class="view-head"><h1>Registry</h1><span class="sub">ministries as configuration objects — secrets by NAME only</span></div>
            <div :for={m <- @ministries} class="panel">
              <div class="panel-head"><h2>{m.name}</h2></div>
              <div style="padding:6px 20px 18px">
                <dl class="kv" style="border:0">
                  <dt>slug</dt><dd class="mono">{m.slug}</dd>
                  <dt>factory</dt><dd class="mono">{m[:instance_id] || "not provisioned"}</dd>
                  <dt>url</dt><dd>{m.url || "—"}</dd>
                  <dt>secrets</dt><dd class="mono" style="font-size:12px">{m[:webhook_secret_env] || "—"} · {m[:api_key_env] || "—"}</dd>
                  <dt>cost cap</dt><dd>{money(m[:cost_cap_usd])} / month</dd>
                  <dt>mode</dt><dd>{m.mode}</dd>
                </dl>
              </div>
            </div>

          <% "policy" -> %>
            <div class="view-head"><h1>Policy</h1><span class="sub">activation rulesets — one document, this grid and the raw JDM</span></div>
            <div :for={m <- @ministries} class="panel">
              <div class="panel-head">
                <h2>{m.name}</h2>
                <span class="seg end">
                  <button :for={mode <- ~w(normal vacation off)} class={m.mode == mode && "on"} phx-click="set_mode" phx-value-id={m.id} phx-value-mode={mode}>{mode}</button>
                </span>
              </div>
              <table class="polgrid">
                <tr><th>#</th><th>class</th><th>mode</th><th>action</th></tr>
                <tr :for={row <- policy_rows(m)}>
                  <td class="mono muted">{row.n}</td>
                  <td class="n">{row.class}</td>
                  <td>{row.mode}</td>
                  <td><span class={"cell #{row.action}"}>{row.action}</span></td>
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
                <a :if={m.url} class="btn sm" href={m.url} target="_blank">Dashboard ↗</a>
              </div>
            </div>
            <.itab_bar itab={@itab} why_label="Evidence" />
            <div class="ipane">
              <%= case @itab do %>
                <% "overview" -> %>
                  <dl class="kv">
                    <dt>factory</dt><dd class="mono">{m[:instance_id] || "not provisioned"}</dd>
                    <dt>state</dt><dd>{m[:box_state] || "—"}</dd>
                    <dt>url</dt><dd>{m.url || "—"}</dd>
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
