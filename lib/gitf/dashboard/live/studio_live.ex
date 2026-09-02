defmodule GiTF.Dashboard.StudioLive do
  @moduledoc """
  The Planning Studio: a live split-pane where a conversation with the
  planner (left) builds the project board (right) in real time.

  All board mutations arrive as `{:studio_update, state}` broadcasts from
  `GiTF.Studio.Session` — the LiveView renders session state and forwards
  user intents (messages, card confirmations, approval); it owns no planning
  state of its own. Pending proposal cards render translucent until
  confirmed. Mockups render in fully-sandboxed iframes (`sandbox=""` — no
  scripts, no same-origin), so generated HTML can't touch the dashboard.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  alias GiTF.Studio.Session

  @impl true
  def mount(%{"session_id" => id}, _session, socket) do
    if Session.alive?(id) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(GiTF.PubSub, Session.topic(id))

      {:ok,
       socket
       |> assign(:page_title, "Planning Studio")
       |> assign(:current_path, "/dashboard/studio")
       |> assign(:session_id, id)
       |> assign(:studio, Session.get_state(id))
       |> assign(:tab, "brief")
       |> assign(:message, "")
       |> assign(:zoomed_mockup, nil)
       |> assign(:show_approve, false)
       |> assign(:sectors, safe_sectors())
       |> assign(:voice_available, GiTF.Studio.VoiceSession.enabled?())
       |> assign(:voice_on, false)
       |> init_toasts()}
    else
      {:ok,
       socket |> put_flash(:error, "Studio session expired") |> redirect(to: "/dashboard/studio")}
    end
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      case Session.start_session() do
        {:ok, id} ->
          {:ok, push_navigate(socket, to: "/dashboard/studio/#{id}")}

        {:error, reason} ->
          {:ok,
           socket
           |> assign(:page_title, "Planning Studio")
           |> assign(:current_path, "/dashboard/studio")
           |> assign(:session_id, nil)
           |> assign(:boot_error, inspect(reason))
           |> init_toasts()}
      end
    else
      {:ok,
       socket
       |> assign(:page_title, "Planning Studio")
       |> assign(:current_path, "/dashboard/studio")
       |> assign(:session_id, nil)
       |> assign(:boot_error, nil)
       |> init_toasts()}
    end
  end

  @impl true
  def handle_info({:studio_update, state}, socket) do
    {:noreply, assign(socket, :studio, state)}
  end

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    text = String.trim(text)

    if text != "" do
      Session.user_message(socket.assigns.session_id, text)
    end

    {:noreply, assign(socket, :message, "")}
  end

  def handle_event("confirm_card", %{"id" => id}, socket) do
    Session.confirm_proposal(socket.assigns.session_id, id)
    {:noreply, socket}
  end

  def handle_event("dismiss_card", %{"id" => id}, socket) do
    Session.dismiss_proposal(socket.assigns.session_id, id)
    {:noreply, socket}
  end

  def handle_event("choose_scheme", %{"id" => id, "scheme" => scheme}, socket) do
    Session.choose_scheme(socket.assigns.session_id, id, scheme)
    {:noreply, socket}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("toggle_voice", _params, socket) do
    on = !socket.assigns.voice_on

    {:noreply,
     push_event(socket, "voice_toggle", %{on: on, session_id: socket.assigns.session_id})}
  end

  def handle_event("voice_started", _params, socket),
    do: {:noreply, assign(socket, :voice_on, true)}

  def handle_event("voice_stopped", _params, socket),
    do: {:noreply, assign(socket, :voice_on, false)}

  def handle_event("voice_client_error", params, socket) do
    {:noreply,
     socket
     |> assign(:voice_on, false)
     |> push_toast(:error, "Voice session error: #{params["reason"] || "unknown"}")}
  end

  def handle_event("zoom_mockup", %{"id" => id}, socket) do
    {:noreply, assign(socket, :zoomed_mockup, id)}
  end

  def handle_event("close_zoom", _params, socket) do
    {:noreply, assign(socket, :zoomed_mockup, nil)}
  end

  def handle_event("show_approve", _params, socket) do
    {:noreply, assign(socket, :show_approve, true)}
  end

  def handle_event("cancel_approve", _params, socket) do
    {:noreply, assign(socket, :show_approve, false)}
  end

  def handle_event("approve", %{"approve" => params}, socket) do
    sector_spec =
      case params do
        %{"mode" => "new", "new_name" => name} when name != "" -> {:new, name}
        %{"sector_id" => sid} when sid != "" -> {:existing, sid}
        _ -> nil
      end

    if sector_spec do
      case Session.approve(socket.assigns.session_id, sector_spec) do
        {:ok, project} ->
          {:noreply,
           socket
           |> put_flash(:info, "Project #{project.name} approved — Aramaki is on it.")
           |> redirect(to: "/dashboard/missions")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:show_approve, false)
           |> push_toast(:error, "Approval failed: #{inspect(reason)}")}
      end
    else
      {:noreply, push_toast(socket, :error, "Pick an existing sector or name a new one.")}
    end
  end

  # -- Render --------------------------------------------------------------------

  @impl true
  def render(%{session_id: nil} = assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <h1 class="page-title">Planning Studio</h1>
      <%= if assigns[:boot_error] do %>
        <p style="color:var(--crit)">Could not start a studio session: {@boot_error}</p>
      <% else %>
        <p style="color:var(--muted)">Starting session…</p>
      <% end %>
    </.live_component>
    """
  end

  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.75rem">
        <h1 class="page-title" style="margin:0">Planning Studio</h1>
        <div style="display:flex; gap:0.35rem; align-items:center">
          <%= for {phase, cost} <- phases_with_cost() do %>
            <span class={"badge #{if @studio.phase == phase, do: "badge-green", else: "badge-grey"}"}
                  title={"Cost of changing your mind here: #{cost}"}>{phase}</span>
            <%= if phase != "review" do %><span style="color:var(--line)">→</span><% end %>
          <% end %>
          <span style="font-size:0.7rem; color:var(--muted); margin-left:0.4rem"
                title="Gates are signed by confirming the planner's phase card. Cost of change rises left to right.">
            change: {commitment(@studio.phase)}
          </span>
          <button phx-click="show_approve" class="btn btn-green" style="margin-left:0.75rem" disabled={@studio.roadmap == []}>
            Approve roadmap ({length(@studio.roadmap)})
          </button>
        </div>
      </div>

      <div style="display:grid; grid-template-columns: 400px 1fr; gap:1rem; align-items:start">
        <%!-- Conversation rail --%>
        <div class="card" style="display:flex; flex-direction:column; height:calc(100vh - 180px)">
          <div id="studio-transcript" style="flex:1; overflow-y:auto; display:flex; flex-direction:column; gap:0.6rem; padding-right:0.25rem" phx-hook="ScrollBottom">
            <%= for entry <- @studio.transcript do %>
              <div style={transcript_style(entry.role)}>
                <div style="font-size:0.7rem; color:var(--muted); margin-bottom:0.15rem">{entry.role}</div>
                <div style="white-space:pre-wrap; font-size:0.85rem">{entry.text}</div>
              </div>
            <% end %>
            <%= if @studio.status == :thinking do %>
              <div style="color:var(--muted); font-size:0.8rem">planner is thinking…</div>
            <% end %>
          </div>
          <form phx-submit="send" style="display:flex; gap:0.5rem; margin-top:0.6rem">
            <input type="text" name="message[text]" value={@message} placeholder="Talk to the planner…" autocomplete="off"
                   style="flex:1; background:var(--ground); border:1px solid var(--line); border-radius:6px; color:var(--text); padding:0.5rem 0.7rem" />
            <button type="submit" class="btn btn-blue">Send</button>
            <%= if @voice_available do %>
              <button type="button" phx-click="toggle_voice" id="studio-voice" phx-hook="StudioVoice"
                      class={"btn #{if @voice_on, do: "btn-red", else: "btn-grey"}"}
                      title={if @voice_on, do: "Stop voice session", else: "Start voice session"}>
                <%= if @voice_on do %>◉ Stop<% else %>🎙 Voice<% end %>
              </button>
            <% end %>
          </form>
        </div>

        <%!-- Board --%>
        <div>
          <%!-- Pending proposal (ghost) cards --%>
          <%= if @studio.proposals != [] do %>
            <div style="display:flex; flex-wrap:wrap; gap:0.5rem; margin-bottom:0.75rem">
              <%= for prp <- @studio.proposals do %>
                <%= if prp.tool == "propose_schemes" do %>
                  <div style="border:1px dashed var(--warn); background:rgba(210,153,34,0.06); border-radius:8px; padding:0.6rem 0.7rem; width:100%">
                    <div style="font-size:0.7rem; color:var(--warn); margin-bottom:0.4rem">
                      Three schemes — {prp.args["axis"]}
                    </div>
                    <div style="display:flex; gap:0.6rem; flex-wrap:wrap">
                      <%= for scheme <- prp.args["schemes"] || [] do %>
                        <div style="flex:1; min-width:200px; border:1px solid var(--line); border-radius:6px; padding:0.5rem; background:var(--ground)">
                          <div style="font-weight:600; margin-bottom:0.25rem">{scheme["name"]}</div>
                          <div style="font-size:0.78rem; color:var(--text); margin-bottom:0.3rem">{scheme["thesis"]}</div>
                          <div style="font-size:0.72rem; color:var(--crit); margin-bottom:0.4rem">sacrifices: {scheme["sacrifice"]}</div>
                          <button phx-click="choose_scheme" phx-value-id={prp.id} phx-value-scheme={scheme["name"]}
                                  class="btn btn-green" style="font-size:0.7rem; padding:0.15rem 0.5rem">Choose</button>
                        </div>
                      <% end %>
                    </div>
                    <button phx-click="dismiss_card" phx-value-id={prp.id} class="btn btn-grey" style="font-size:0.7rem; padding:0.15rem 0.5rem; margin-top:0.4rem">✕ None of these</button>
                  </div>
                <% else %>
                  <div style="border:1px dashed var(--accent); background:rgba(88,166,255,0.07); border-radius:8px; padding:0.5rem 0.7rem; max-width:340px; opacity:0.85">
                    <div style="font-size:0.7rem; color:var(--accent); margin-bottom:0.2rem">{card_label(prp.tool)}</div>
                    <div style="font-size:0.8rem; margin-bottom:0.4rem">{card_text(prp)}</div>
                    <div style="display:flex; gap:0.4rem">
                      <button phx-click="confirm_card" phx-value-id={prp.id} class="btn btn-green" style="font-size:0.7rem; padding:0.15rem 0.5rem">✓ Confirm</button>
                      <button phx-click="dismiss_card" phx-value-id={prp.id} class="btn btn-grey" style="font-size:0.7rem; padding:0.15rem 0.5rem">✕ Dismiss</button>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%!-- Tabs --%>
          <div style="display:flex; gap:0.25rem; margin-bottom:0.75rem">
            <%= for {tab, label, count} <- tabs(@studio) do %>
              <button phx-click="set_tab" phx-value-tab={tab}
                      class={"btn #{if @tab == tab, do: "btn-blue", else: "btn-grey"}"} style="font-size:0.8rem">
                {label}<%= if count > 0 do %> ({count})<% end %>
              </button>
            <% end %>
          </div>

          <%= case @tab do %>
            <% "brief" -> %><.brief_board studio={@studio} />
            <% "concept" -> %><.concept_graph studio={@studio} />
            <% "roadmap" -> %><.roadmap_board studio={@studio} />
            <% "mockups" -> %><.mockup_gallery studio={@studio} zoomed={@zoomed_mockup} />
            <% "story" -> %><.storyboard_strip studio={@studio} />
          <% end %>
        </div>
      </div>

      <%!-- Approve modal --%>
      <%= if @show_approve do %>
        <div style="position:fixed; inset:0; background:rgba(0,0,0,0.6); display:flex; align-items:center; justify-content:center; z-index:50">
          <div class="card" style="width:440px">
            <h3 style="margin-top:0">Approve &amp; hand to Aramaki</h3>
            <p style="color:var(--muted); font-size:0.85rem">{length(@studio.roadmap)} mission(s) will run in dependency order.</p>
            <form phx-submit="approve">
              <label style="display:block; margin-bottom:0.5rem">
                <input type="radio" name="approve[mode]" value="existing" checked /> Existing sector
                <select name="approve[sector_id]" style="width:100%; margin-top:0.3rem; background:var(--ground); color:var(--text); border:1px solid var(--line); border-radius:6px; padding:0.4rem">
                  <option value="">— pick —</option>
                  <%= for s <- @sectors do %><option value={s.id}>{s.name}</option><% end %>
                </select>
              </label>
              <label style="display:block; margin-bottom:0.9rem">
                <input type="radio" name="approve[mode]" value="new" /> New repository (git init)
                <input type="text" name="approve[new_name]" placeholder="repo-name" style="width:100%; margin-top:0.3rem; background:var(--ground); color:var(--text); border:1px solid var(--line); border-radius:6px; padding:0.4rem" />
              </label>
              <div style="display:flex; gap:0.5rem; justify-content:flex-end">
                <button type="button" phx-click="cancel_approve" class="btn btn-grey">Cancel</button>
                <button type="submit" class="btn btn-green">Approve</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </.live_component>
    """
  end

  # -- Board components ------------------------------------------------------------

  defp brief_board(assigns) do
    ~H"""
    <div style="display:grid; grid-template-columns: 1fr 1fr; gap:0.75rem">
      <div class="card" style="grid-column: 1 / -1; display:flex; gap:1rem">
        <div style="flex:1">
          <div style="font-size:0.7rem; color:var(--muted); text-transform:uppercase">Vision</div>
          <div style="font-size:0.95rem">{@studio.brief.vision || em("not set yet")}</div>
        </div>
        <div style="flex:1; border-left:1px solid var(--line); padding-left:1rem">
          <div style="font-size:0.7rem; color:var(--warn); text-transform:uppercase">Parti — the one idea</div>
          <div style="font-size:0.95rem">{@studio.brief.parti || em("not set yet")}</div>
        </div>
      </div>

      <div class="card">
        <div style="font-size:0.75rem; color:var(--ok); text-transform:uppercase; margin-bottom:0.5rem">Decided</div>
        <%= if @studio.brief.decisions == [] do %>{em("nothing yet")}<% end %>
        <%= for d <- @studio.brief.decisions do %>
          <div style="border-left:3px solid var(--ok); padding:0.3rem 0.6rem; margin-bottom:0.4rem; background:var(--ground); border-radius:0 6px 6px 0; font-size:0.85rem">{d}</div>
        <% end %>
        <%= if @studio.brief.constraints != [] do %>
          <div style="font-size:0.75rem; color:var(--crit); text-transform:uppercase; margin:0.75rem 0 0.5rem">Constraints</div>
          <%= for c <- @studio.brief.constraints do %>
            <div style="border-left:3px solid var(--crit); padding:0.3rem 0.6rem; margin-bottom:0.4rem; background:var(--ground); border-radius:0 6px 6px 0; font-size:0.85rem">{c}</div>
          <% end %>
        <% end %>
      </div>

      <div class="card">
        <div style="font-size:0.75rem; color:var(--warn); text-transform:uppercase; margin-bottom:0.5rem">Open questions</div>
        <%= if @studio.brief.open_questions == [] do %>{em("none — nice")}<% end %>
        <%= for q <- @studio.brief.open_questions do %>
          <div style="display:inline-block; border:1px solid var(--warn); color:var(--warn); padding:0.2rem 0.6rem; margin:0 0.3rem 0.3rem 0; border-radius:999px; font-size:0.8rem">{q}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp concept_graph(assigns) do
    modules = assigns.studio.modules
    n = max(length(modules), 1)

    positions =
      modules
      |> Enum.with_index()
      |> Map.new(fn {m, i} ->
        angle = 2 * :math.pi() * i / n - :math.pi() / 2
        {m.id, {400 + 260 * :math.cos(angle), 260 + 190 * :math.sin(angle)}}
      end)

    placed_modules =
      Enum.map(modules, fn m ->
        {x, y} = positions[m.id]
        Map.merge(m, %{x: x, y: y})
      end)

    placed_edges =
      assigns.studio.edges
      |> Enum.flat_map(fn edge ->
        case {positions[edge.from], positions[edge.to]} do
          {{x1, y1}, {x2, y2}} -> [Map.merge(edge, %{x1: x1, y1: y1, x2: x2, y2: y2})]
          _ -> []
        end
      end)

    assigns = assign(assigns, modules: placed_modules, edges: placed_edges)

    ~H"""
    <div class="card">
      <%= if @modules == [] do %>
        {em("The module graph builds itself as you talk through the concept.")}
      <% else %>
        <svg viewBox="0 0 800 520" style="width:100%; max-height:520px">
          <%= for edge <- @edges do %>
            <line x1={edge.x1} y1={edge.y1} x2={edge.x2} y2={edge.y2} stroke={edge_color(edge.kind)}
                  stroke-width="2" stroke-dasharray={if edge.kind == "isolated_from", do: "6 4", else: ""} />
            <text x={(edge.x1 + edge.x2) / 2} y={(edge.y1 + edge.y2) / 2 - 6} fill="var(--muted)" font-size="10" text-anchor="middle">{edge.kind}</text>
          <% end %>
          <%= for m <- @modules do %>
            <circle cx={m.x} cy={m.y} r={radius(m.effort)} fill="rgba(88,166,255,0.15)" stroke="var(--accent)" stroke-width="2" />
            <text x={m.x} y={m.y} fill="var(--text)" font-size="13" text-anchor="middle" dominant-baseline="middle">{m.label}</text>
          <% end %>
        </svg>
      <% end %>
    </div>
    """
  end

  defp roadmap_board(assigns) do
    assigns = assign(assigns, :levels, dag_levels(assigns.studio.roadmap))

    ~H"""
    <div class="card">
      <%= if @levels == [] do %>
        {em("Roadmap items appear here once the concept settles.")}
      <% else %>
        <%= for {level, idx} <- Enum.with_index(@levels) do %>
          <div style="display:flex; gap:0.75rem; margin-bottom:0.75rem; align-items:stretch">
            <div style="color:var(--muted); font-size:0.75rem; writing-mode:vertical-rl; text-align:center">wave {idx + 1}</div>
            <%= for item <- level do %>
              <div style="flex:1; border:1px solid var(--line); border-radius:8px; padding:0.6rem; background:var(--ground); max-width:320px">
                <div style="font-size:0.7rem; color:var(--warn)">[{item.id}]</div>
                <div style="font-weight:600; margin:0.15rem 0">{item.title}</div>
                <div style="font-size:0.78rem; color:var(--muted); max-height:4.5em; overflow:hidden">{String.slice(item.goal, 0, 220)}</div>
                <%= if item.depends_on != [] do %>
                  <div style="font-size:0.7rem; color:var(--accent); margin-top:0.3rem">after: {Enum.join(item.depends_on, ", ")}</div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp mockup_gallery(assigns) do
    ~H"""
    <div>
      <%= if @studio.mockups == [] do %>
        <div class="card">{em("Ask the planner to mock something up — variants land here side by side.")}</div>
      <% else %>
        <div style="display:grid; grid-template-columns:repeat(auto-fill, minmax(320px, 1fr)); gap:0.75rem">
          <%= for m <- @studio.mockups do %>
            <div class="card" style="padding:0.5rem">
              <div style="display:flex; justify-content:space-between; margin-bottom:0.4rem">
                <span style="font-size:0.75rem; color:var(--muted)">{m.target} — <span style="color:var(--warn)">{m.style}</span></span>
                <button phx-click="zoom_mockup" phx-value-id={m.id} class="btn btn-grey" style="font-size:0.7rem; padding:0.1rem 0.4rem">⤢</button>
              </div>
              <iframe sandbox="" srcdoc={m.html} style="width:100%; height:260px; border:1px solid var(--line); border-radius:6px; background:#fff"></iframe>
            </div>
          <% end %>
        </div>
        <%= for m <- Enum.filter(@studio.mockups, &(&1.id == @zoomed)) do %>
          <div phx-click="close_zoom" style="position:fixed; inset:0; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; z-index:60">
            <iframe sandbox="" srcdoc={m.html} style="width:85vw; height:85vh; border-radius:8px; background:#fff"></iframe>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # -- Helpers -----------------------------------------------------------------------

  defp tabs(studio) do
    [
      {"brief", "Brief", length(studio.brief.decisions) + length(studio.brief.open_questions)},
      {"concept", "Concept graph", length(studio.modules)},
      {"roadmap", "Roadmap", length(studio.roadmap)},
      {"mockups", "Mockups", length(studio.mockups)},
      {"story", "Story", length(studio.storyboards)}
    ]
  end

  defp storyboard_strip(assigns) do
    ~H"""
    <div class="card">
      <%= if @studio.storyboards == [] do %>
        {em("Confirmed storyboards land here — the key journey, panel by panel.")}
      <% else %>
        <%= for board <- @studio.storyboards do %>
          <div style="margin-bottom:1rem">
            <div style="font-weight:600; margin-bottom:0.5rem">{board.title}</div>
            <div style="display:flex; gap:0.6rem; overflow-x:auto; padding-bottom:0.5rem">
              <%= for {panel, idx} <- Enum.with_index(board.panels, 1) do %>
                <div style="min-width:190px; max-width:190px; border:1px solid var(--line); border-radius:8px; background:var(--ground); padding:0.5rem">
                  <div style="font-size:0.7rem; color:var(--warn); margin-bottom:0.25rem">panel {idx}</div>
                  <div style="font-size:0.85rem; font-weight:600; margin-bottom:0.3rem">{panel["caption"]}</div>
                  <div style="font-size:0.75rem; color:var(--muted)">{panel["description"]}</div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp phases_with_cost do
    [
      {"brief", "minutes — talk is cheap"},
      {"concept", "minutes — regenerate a few cards"},
      {"roadmap", "tens of minutes — missions re-planned"},
      {"review", "hours+ — approved missions burn real budget"}
    ]
  end

  defp commitment("brief"), do: "cheap"
  defp commitment("concept"), do: "cheap"
  defp commitment("roadmap"), do: "moderate"
  defp commitment(_), do: "expensive"

  defp transcript_style(:user),
    do:
      "align-self:flex-end; background:var(--accent)22; border:1px solid var(--accent)55; border-radius:10px 10px 2px 10px; padding:0.45rem 0.65rem; max-width:90%"

  defp transcript_style(:assistant),
    do:
      "align-self:flex-start; background:var(--panel); border:1px solid var(--line); border-radius:10px 10px 10px 2px; padding:0.45rem 0.65rem; max-width:95%"

  defp transcript_style(_),
    do: "align-self:center; color:var(--warn); font-size:0.75rem; padding:0.2rem"

  defp card_label(tool),
    do: tool |> String.replace(["upsert_", "add_", "set_"], "") |> String.replace("_", " ")

  defp card_text(%{args: args}) do
    args["text"] || args["title"] || args["label"] ||
      (args["from"] && "#{args["from"]} → #{args["to"]}") || args["id"] || "?"
  end

  defp radius("s"), do: 34
  defp radius("l"), do: 62
  defp radius(_), do: 46

  defp edge_color("isolated_from"), do: "var(--crit)"
  defp edge_color("shares_data"), do: "var(--warn)"
  defp edge_color(_), do: "var(--accent)"

  defp em(text),
    do: Phoenix.HTML.raw("<span style=\"color:var(--muted); font-style:italic\">#{text}</span>")

  defp safe_sectors do
    GiTF.Sector.list()
  rescue
    _ -> []
  end

  # Topological waves for the roadmap board.
  defp dag_levels(items) do
    do_levels(items, MapSet.new(), [])
  end

  defp do_levels([], _done, acc), do: Enum.reverse(acc)

  defp do_levels(items, done, acc) do
    {ready, blocked} =
      Enum.split_with(items, fn item ->
        Enum.all?(item.depends_on, &MapSet.member?(done, &1))
      end)

    case ready do
      # Malformed deps (mid-edit): render the rest as one final wave.
      [] -> Enum.reverse([items | acc])
      _ -> do_levels(blocked, Enum.into(ready, done, & &1.id), [ready | acc])
    end
  end
end
