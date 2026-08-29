defmodule GiTF.Dashboard.DesignLive do
  @moduledoc "Design phase viewer — compare strategy variants, review analysis, and approval."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable
  import GiTF.Dashboard.Helpers

  @strategies ["minimal", "normal", "complex"]
  @default_strategy "normal"
  @strategy_colors %{"minimal" => "#58a6ff", "normal" => "#3fb950", "complex" => "#a78bfa"}
  @strategy_instructions Map.new(@strategies, fn s ->
                           {s, GiTF.Major.Planner.strategy_instruction(s, nil)}
                         end)
  @refresh_ms 5_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
          Process.send_after(self(), :refresh, @refresh_ms)
        end

        socket =
          socket
          |> assign(:page_title, "Design: #{Map.get(mission, :name, "Mission")}")
          |> assign(:current_path, "/dashboard/missions")
          |> assign(:strategy_list, @strategies)
          |> assign(:strategy_instructions, @strategy_instructions)
          |> assign(:collapsed, MapSet.new())
          |> assign(:override_selection, nil)
          |> assign(:refresh_scheduled, false)
          |> init_toasts()
          |> refresh_data(mission)

        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Mission not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("toggle_section", %{"section" => section}, socket) do
    {:noreply, assign(socket, :collapsed, toggle_set(socket.assigns.collapsed, section))}
  end

  # Synthesis takes a model call, so it runs off the LiveView process — the
  # page stays interactive and a slow provider cannot block the socket.
  def handle_event("generate_report", _params, socket) do
    mission_id = socket.assigns.mission.id
    lv = self()

    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
      send(lv, {:design_report, GiTF.Major.DesignReport.generate(mission_id)})
    end)

    {:noreply, assign(socket, :report_generating, true)}
  end

  def handle_event("select_override", %{"strategy" => strategy}, socket) do
    current = socket.assigns.override_selection

    {:noreply,
     assign(socket, :override_selection, if(current == strategy, do: nil, else: strategy))}
  end

  def handle_event("approve_design", _params, socket) do
    mission = socket.assigns.mission

    case GiTF.Major.Orchestrator.approve_design(mission.id, socket.assigns.override_selection) do
      {:ok, _} ->
        {:ok, mission} = GiTF.Missions.get(mission.id)

        {:noreply,
         socket
         |> put_flash(:info, "Design approved — advancing to planning.")
         |> refresh_data(mission)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approval failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reject_design", _params, socket) do
    mission = socket.assigns.mission

    case GiTF.Major.DesignBoard.reject_design(mission.id, "Human rejected via dashboard") do
      {:ok, _} ->
        {:ok, mission} = GiTF.Missions.get(mission.id)

        {:noreply,
         socket
         |> put_flash(:info, "Design rejected — redesign triggered.")
         |> refresh_data(mission)}

      {:error, :max_redesigns} ->
        {:noreply, put_flash(socket, :error, "Maximum redesign iterations reached.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rejection failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} -> {:noreply, refresh_data(socket, mission)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}
  end

  # Debounced refresh: collapse rapid PubSub events into one mission re-fetch 150ms out.
  def handle_info(:debounced_refresh, socket) do
    case GiTF.Missions.get(socket.assigns.mission.id) do
      {:ok, mission} ->
        {:noreply, socket |> assign(:refresh_scheduled, false) |> refresh_data(mission)}

      _ ->
        {:noreply, assign(socket, :refresh_scheduled, false)}
    end
  end

  def handle_info({:design_report, result}, socket) do
    socket = assign(socket, :report_generating, false)

    case result do
      {:ok, report} ->
        {:noreply, assign(socket, :report, report)}

      {:error, :no_designs} ->
        {:noreply, put_flash(socket, :error, "No designs to compare yet.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Report failed: #{inspect(reason)}")}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
    <.breadcrumbs crumbs={[{"Missions", "/dashboard/missions"}, {Map.get(@mission, :name, "Mission"), "/dashboard/missions/#{@mission.id}"}, {"Design", nil}]} />

    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
      <div>
        <h1 class="page-title" style="margin-bottom:0.25rem">Design: {Map.get(@mission, :name) || short_id(@mission.id)}</h1>
        <div style="color:#8b949e; font-size:0.85rem">{@mission[:goal]}</div>
      </div>
      <div style="display:flex; gap:0.5rem; align-items:center">
        <span class={"badge #{phase_badge(@mission[:current_phase] || "pending")}"}>{@mission[:current_phase] || "pending"}</span>
        <a href={"/dashboard/missions/#{@mission.id}"} class="btn btn-grey">Back</a>
      </div>
    </div>

    <div class="tab-bar" style="margin-bottom:1rem">
      <div :if={length(@strategy_list) > 1} class={"tab #{if @active_tab == "compare", do: "tab-active"}"} phx-click="switch_tab" phx-value-tab="compare">Compare</div>
      <div
        :for={strategy <- @strategy_list}
        class={"tab tab-#{strategy} #{if @active_tab == strategy, do: "tab-active"}"}
        phx-click="switch_tab"
        phx-value-tab={strategy}
        style={if @active_tab == strategy, do: "border-bottom-color: #{strategy_color(strategy)}"}
      >
        {strategy_label(strategy)}
        <span :if={winner?(strategy, @review)} style="color:#d29922; margin-left:0.3rem">★</span>
        <span :if={is_nil(@designs[strategy])} class="loading-spinner" style="width:12px;height:12px;border-width:2px;margin-left:0.4rem"></span>
      </div>
    </div>

    {if @active_tab == "compare", do: render_compare(assigns), else: render_strategy_detail(assigns)}

    <div :if={@mode == :approval} class="panel" style="margin-top:1rem; display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:0.75rem">
      <div style="display:flex; align-items:center; gap:0.5rem">
        <span style="color:#8b949e; font-size:0.85rem">Override selection:</span>
        <button
          :for={s <- @strategy_list}
          class={"override-btn #{if @override_selection == s, do: "active"}"}
          phx-click="select_override"
          phx-value-strategy={s}
          style={"border-color: #{if @override_selection == s, do: strategy_color(s), else: "#30363d"}"}
        >{strategy_label(s)}</button>
      </div>
      <div style="display:flex; gap:0.5rem">
        <button phx-click="approve_design" class="btn btn-green" disabled={is_nil(@review)}>Approve &amp; Plan</button>
        <button phx-click="reject_design" class="btn btn-red" data-confirm="Trigger redesign?">Reject &amp; Redesign</button>
      </div>
    </div>

    </.live_component>
    """
  end

  # -- Compare tab -----------------------------------------------------------

  defp render_compare(assigns) do
    ~H"""
    {render_decision_brief(assigns)}
    <div style="display:grid; grid-template-columns:repeat(3, 1fr); gap:1rem">
      <div :for={strategy <- @strategy_list} class={"strategy-card #{if winner?(strategy, @review), do: "selected"}"}>
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:0.75rem">
          <span class={"badge badge-#{design_strategy_badge(strategy)}"}>{strategy_label(strategy)}</span>
          <span :if={winner?(strategy, @review)} style="background:#d29922; color:#0d1117; padding:0.15rem 0.5rem; border-radius:4px; font-size:0.7rem; font-weight:700">AI PICK</span>
        </div>

        <% design = @designs[strategy] %>
        <div :if={design} style="display:grid; grid-template-columns:1fr 1fr; gap:0.5rem; font-size:0.85rem">
          <div class="card" style="padding:0.5rem">
            <div class="card-label">Components</div>
            <div class="card-value">{length(get_list(design, "components"))}</div>
          </div>
          <div class="card" style="padding:0.5rem">
            <div class="card-label">Files</div>
            <div class="card-value">{count_design_files(design)}</div>
          </div>
          <div class="card" style="padding:0.5rem">
            <div class="card-label">Requirements</div>
            <div class="card-value">{length(get_list(design, "requirement_mapping"))}</div>
          </div>
          <div class="card" style="padding:0.5rem">
            <div class="card-label">Risks</div>
            <div class="card-value">{length(get_list(design, "risks"))}</div>
          </div>
        </div>

        <button :if={design} class="btn btn-grey" style="width:100%; margin-top:0.75rem; font-size:0.85rem" phx-click="switch_tab" phx-value-tab={strategy}>View Details</button>

        <div :if={is_nil(design)} style="text-align:center; padding:2rem 0; color:#8b949e">
          <span class="loading-spinner" style="width:20px;height:20px;border-width:2px"></span>
          <div style="margin-top:0.5rem">Generating...</div>
        </div>
      </div>
    </div>

    {render_file_matrix(assigns)}
    {render_risk_columns(assigns)}
    {render_review_analysis(assigns)}
    """
  end

  # -- Decision brief --------------------------------------------------------

  # The panels below this one show what each strategy proposed and which one
  # won. The brief is the part an operator otherwise writes by hand before
  # agreeing with a plan: whether the strategies genuinely forked, what each
  # one's judgement looked like, and what overriding the pick would cost.
  # On demand, because most missions are never questioned.
  defp render_decision_brief(assigns) do
    ~H"""
    <div class="panel" style="margin-bottom:1rem">
      <div style="display:flex; justify-content:space-between; align-items:center; gap:1rem">
        <div class="panel-title" style="margin:0">Decision Brief</div>
        <a
          :if={@report}
          class="btn btn-grey"
          style="font-size:0.8rem; text-decoration:none; margin-right:0.4rem"
          href={"/dashboard/missions/#{@mission.id}/deck"}
          title="Self-contained page — send it to someone who is not on the tailnet"
        >Download deck</a>
        <button
          class="btn btn-grey"
          style="font-size:0.8rem"
          phx-click="generate_report"
          disabled={@report_generating}
        >
          {cond do
            @report_generating -> "Synthesising…"
            @report -> "Regenerate"
            true -> "Generate"
          end}
        </button>
      </div>

      <div :if={is_nil(@report) && !@report_generating} style="color:#8b949e; font-size:0.85rem; margin-top:0.5rem">
        Reads the competing designs and the review together, and writes up what the
        choice actually was — one model call over artifacts this mission already has.
      </div>

      <div :if={@report}>
        <div style="font-size:1.02rem; line-height:1.5; margin:0.75rem 0 0.5rem">
          {@report["headline"]}
        </div>

        <div :if={@report["convergence"]} style="font-size:0.9rem; color:#c9d1d9; margin-bottom:0.9rem">
          {@report["convergence"]}
        </div>

        <div style="display:grid; grid-template-columns:repeat(auto-fit, minmax(15rem, 1fr)); gap:1rem">
          <div :for={d <- get_list(@report, "designs")}>
            <div style="display:flex; align-items:center; gap:0.4rem; margin-bottom:0.35rem">
              <span class={"badge badge-#{design_strategy_badge(d["strategy"])}"}>{strategy_label(d["strategy"])}</span>
              <span :if={winner?(d["strategy"], @review)} style="color:#d29922">★</span>
            </div>
            <div style="font-size:0.85rem; margin-bottom:0.4rem">{d["character"]}</div>
            <div :for={n <- List.wrap(d["notable"])} style="font-size:0.82rem; color:#8b949e">
              <span class="coverage-ok">✓</span> {n}
            </div>
            <div :for={m <- List.wrap(d["missed"])} style="font-size:0.82rem; color:#8b949e">
              <span style="color:#f85149">✗</span> {m}
            </div>
          </div>
        </div>

        <div :if={@report["decision"]} style="font-size:0.9rem; margin-top:0.9rem; padding-left:0.75rem; border-left:2px solid #d29922">
          {@report["decision"]}
        </div>

        <div :if={get_list(@report, "watch_items") != []} style="margin-top:0.9rem">
          <div style="color:#8b949e; font-size:0.8rem; margin-bottom:0.35rem">Watch Items</div>
          <div :for={w <- get_list(@report, "watch_items")} class="issue-item issue-medium">
            <div style="font-size:0.85rem">{w["concern"]}</div>
            <div :if={w["why_it_matters"]} style="font-size:0.8rem; color:#8b949e; margin-top:0.2rem">
              → {w["why_it_matters"]}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Convergence: which files does each strategy actually touch? ------------

  # The first question when comparing designs is whether they genuinely differ
  # or just describe the same change with different amounts of prose. Every
  # design names its files, so that question is answerable mechanically:
  # agreed rows are noise, the divergent ones are the whole decision.
  defp render_file_matrix(assigns) do
    cmp = file_divergence(Enum.map(assigns.strategy_list, &{&1, assigns.designs[&1]}))

    assigns =
      assign(assigns,
        present_strategies: cmp.strategies,
        divergent: Enum.reject(cmp.rows, fn {_, _, all?} -> all? end),
        agreed_count: cmp.agreed,
        total_files: cmp.total
      )

    ~H"""
    <div :if={@total_files > 0} class="panel" style="margin-top:1rem">
      <div class="panel-title">Files Touched</div>
      <div style="color:#8b949e; font-size:0.85rem; margin:0.5rem 0 0.75rem">
        {@agreed_count} of {@total_files} files are in every design — the strategies agree on those.
        <span :if={@divergent == []}>They agree on all of them: this was a choice about rigor, not architecture.</span>
        <span :if={@divergent != []}>The {length(@divergent)} below are where they diverge.</span>
      </div>

      <div :if={@divergent != []} style="overflow-x:auto">
        <table class="table" style="min-width:32rem">
          <thead>
            <tr>
              <th>File</th>
              <th :for={s <- @present_strategies} style="text-align:center">{strategy_label(s)}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{file, touched, _} <- @divergent}>
              <td style="font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:0.82rem">{file}</td>
              <td :for={s <- @present_strategies} style="text-align:center">
                <span :if={s in touched} class="coverage-ok">✓</span>
                <span :if={s not in touched} style="color:#484f58">—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # -- Risks, three-up -------------------------------------------------------

  # Each design's risk list is where its judgement shows: what one strategy
  # foresaw and another missed is the real argument for the pick. Reading them
  # meant opening three tabs and holding them in your head; side by side, the
  # gaps are visible at a glance.
  defp render_risk_columns(assigns) do
    ~H"""
    <div class="panel" style="margin-top:1rem">
      <div class="panel-title">Risks Foreseen</div>
      <div style="display:grid; grid-template-columns:repeat(auto-fit, minmax(15rem, 1fr)); gap:1rem; margin-top:0.75rem">
        <div :for={strategy <- @strategy_list}>
          <div style="display:flex; align-items:center; gap:0.4rem; margin-bottom:0.5rem">
            <span class={"badge badge-#{design_strategy_badge(strategy)}"}>{strategy_label(strategy)}</span>
            <span :if={winner?(strategy, @review)} style="color:#d29922">★</span>
          </div>
          <% design = @designs[strategy] %>
          <ol :if={design} style="margin:0; padding-left:1.1rem; display:flex; flex-direction:column; gap:0.5rem">
            <li :for={risk <- get_list(design, "risks")} style="font-size:0.83rem; line-height:1.5">{risk}</li>
          </ol>
          <div :if={design && get_list(design, "risks") == []} style="color:#8b949e; font-size:0.85rem">
            None recorded.
          </div>
          <div :if={is_nil(design)} style="color:#8b949e; font-size:0.85rem">Generating…</div>
        </div>
      </div>
    </div>
    """
  end

  # -- Strategy detail tab ---------------------------------------------------

  defp render_strategy_detail(assigns) do
    strategy = assigns.active_tab
    design = assigns.designs[strategy]

    assigns =
      assign(assigns,
        strategy: strategy,
        design: design,
        is_winner: winner?(strategy, assigns.review)
      )

    ~H"""
    <div>
      <div>
        <div :if={@design} class={if @is_winner, do: "design-winner", else: ""} style="margin-bottom:1rem">
          {render_collapsible(assigns, "prompt_#{@strategy}", "Strategy Prompt", fn ->
            assigns |> assign(:content, @strategy_instructions[@strategy]) |> render_prompt_content()
          end)}
          {render_collapsible(assigns, "components_#{@strategy}", "Components (#{length(get_list(@design, "components"))})", fn ->
            assigns |> render_components()
          end)}
          {render_collapsible(assigns, "reqs_#{@strategy}", "Requirement Mapping (#{length(get_list(@design, "requirement_mapping"))})", fn ->
            assigns |> render_requirements()
          end)}
          {render_collapsible(assigns, "deps_#{@strategy}", "Dependencies (#{length(get_list(@design, "dependencies"))})", fn ->
            assigns |> render_dependencies()
          end)}
          {render_collapsible(assigns, "risks_#{@strategy}", "Risks (#{length(get_list(@design, "risks"))})", fn ->
            assigns |> render_risks()
          end)}
        </div>

        <div :if={is_nil(@design)} class="panel" style="text-align:center; padding:3rem">
          <span class="loading-spinner" style="width:24px;height:24px;border-width:2px"></span>
          <div style="margin-top:0.75rem; color:#8b949e">Design generation in progress...</div>
        </div>
      </div>

    </div>
    """
  end

  # -- Review analysis -------------------------------------------------------

  # Lives on the Compare tab, not beside an individual design: the review's
  # job is to choose *among* the three, so its coverage, issues, and risk
  # assessment only make sense next to all of them. Repeating it in each
  # strategy's sidebar implied it was about that one design.
  defp render_review_analysis(assigns) do
    ~H"""
    <div class="panel" style="margin-top:1rem">
      <div class="panel-title">Review Analysis</div>
      <div :if={@review}>
        <div style="margin:0.75rem 0">
          <div style="color:#8b949e; font-size:0.8rem; margin-bottom:0.25rem">Selected Design</div>
          <span class={"badge badge-#{design_strategy_badge(selected_strategy(@review))}"}>{strategy_label(selected_strategy(@review))}</span>
          <span :if={@review["approved"]} class="badge badge-green" style="margin-left:0.3rem">Approved</span>
          <span :if={@review["approved"] != true} class="badge badge-yellow" style="margin-left:0.3rem">Needs Review</span>
        </div>

        <div class="review-split">
          <div style="margin:0.75rem 0">
            <div style="color:#8b949e; font-size:0.8rem; margin-bottom:0.35rem">Coverage</div>
            <div :for={cov <- get_list(@review, "coverage")} class="coverage-item">
              <span :if={cov["covered"]} class="coverage-ok">✓</span>
              <span :if={cov["covered"] != true} class="coverage-gap">✗</span>
              <span style="font-weight:600; white-space:nowrap">{cov["req_id"]}</span>
              <span :if={@requirement_index[cov["req_id"]]} style="color:#8b949e">
                {@requirement_index[cov["req_id"]]}
              </span>
              <span :if={cov["gap"]} style="color:#f85149; font-size:0.8rem">({cov["gap"]})</span>
            </div>
          </div>

          <div style="margin:0.75rem 0">
            <div style="color:#8b949e; font-size:0.8rem; margin-bottom:0.35rem">Issues ({length(get_list(@review, "issues"))})</div>
            <div :for={issue <- sort_issues(get_list(@review, "issues"))} class={"issue-item issue-#{issue["severity"] || "low"}"}>
              <div style="font-weight:600; font-size:0.8rem; text-transform:uppercase">{issue["severity"] || "info"}</div>
              <div style="font-size:0.85rem">{issue["description"]}</div>
              <div :if={issue["suggestion"]} style="font-size:0.8rem; color:#8b949e; margin-top:0.2rem">→ {issue["suggestion"]}</div>
            </div>
            <div :if={get_list(@review, "issues") == []} style="color:#3fb950; font-size:0.85rem">No issues found.</div>
          </div>
        </div>

        <div style="margin:0.75rem 0">
          <div style="color:#8b949e; font-size:0.8rem; margin-bottom:0.25rem">Risk Assessment</div>
          <div style="font-size:0.85rem">{@review["risk_assessment"] || "—"}</div>
        </div>
      </div>

      <div :if={is_nil(@review)} style="text-align:center; padding:2rem 0; color:#8b949e">
        <span class="loading-spinner" style="width:16px;height:16px;border-width:2px"></span>
        <div style="margin-top:0.5rem; font-size:0.85rem">Awaiting review...</div>
      </div>
    </div>
    """
  end

  # -- Collapsible section helper --------------------------------------------

  defp render_collapsible(assigns, section_id, title, render_fn) do
    open = not MapSet.member?(assigns.collapsed, section_id)

    assigns =
      assign(assigns,
        section_id: section_id,
        section_title: title,
        section_open: open,
        section_render_fn: render_fn
      )

    ~H"""
    <div class="section-header" phx-click="toggle_section" phx-value-section={@section_id}>
      <span class={"section-chevron #{if @section_open, do: "open"}"}>▸</span>
      {@section_title}
    </div>
    <div :if={@section_open}>{@section_render_fn.()}</div>
    """
  end

  defp render_prompt_content(assigns) do
    ~H"""
    <div style="padding:0.5rem 0; color:#8b949e; font-size:0.85rem; white-space:pre-wrap">{@content}</div>
    """
  end

  defp render_components(assigns) do
    ~H"""
    <div :for={comp <- get_list(@design, "components")} class="component-card">
      <div style="font-weight:600; color:#f0f6fc; margin-bottom:0.3rem">{comp["name"] || "unnamed"}</div>
      <div style="font-size:0.85rem; color:#8b949e; margin-bottom:0.4rem">{comp["description"]}</div>
      <div :if={comp["files"] && comp["files"] != []} style="margin-bottom:0.3rem">
        <span :for={f <- List.wrap(comp["files"])} class="file-tag">{f}</span>
      </div>
      <div :if={comp["interfaces"] && comp["interfaces"] != []} style="font-size:0.8rem; color:#8b949e">
        <code :for={iface <- List.wrap(comp["interfaces"])} style="background:#21262d; padding:0.1rem 0.4rem; border-radius:3px; margin-right:0.3rem">{iface}</code>
      </div>
    </div>
    """
  end

  defp render_requirements(assigns) do
    ~H"""
    <table style="width:100%; margin-top:0.25rem">
      <thead><tr><th style="width:80px">Req</th><th style="width:140px">Component</th><th>Approach</th></tr></thead>
      <tbody>
        <tr :for={req <- get_list(@design, "requirement_mapping")}>
          <td style="font-family:monospace; font-size:0.8rem">{req["req_id"]}</td>
          <td>{req["component"]}</td>
          <td style="font-size:0.85rem; color:#8b949e">{req["approach"]}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp render_dependencies(assigns) do
    ~H"""
    <div style="padding:0.5rem 0">
      <div :for={dep <- get_list(@design, "dependencies")} style="font-size:0.85rem; padding:0.2rem 0">
        <code>{dep["from"]}</code>
        <span style="color:#8b949e; margin:0 0.5rem">→</span>
        <code>{dep["to"]}</code>
      </div>
      <div :if={get_list(@design, "dependencies") == []} style="color:#8b949e; font-size:0.85rem">No dependencies listed.</div>
    </div>
    """
  end

  defp render_risks(assigns) do
    ~H"""
    <div style="padding:0.5rem 0">
      <div :for={risk <- get_list(@design, "risks")} style="font-size:0.85rem; padding:0.2rem 0; color:#d29922">
        • {if is_binary(risk), do: risk, else: inspect(risk)}
      </div>
      <div :if={get_list(@design, "risks") == []} style="color:#8b949e; font-size:0.85rem">No risks identified.</div>
    </div>
    """
  end

  # -- Data loading ----------------------------------------------------------

  defp refresh_data(socket, mission) do
    # In fast mode, only the minimal strategy is used
    active_strategies =
      if Map.get(mission, :pipeline_mode) == "fast",
        do: ["minimal"],
        else: @strategies

    designs =
      Map.new(active_strategies, fn s ->
        {s, GiTF.Missions.get_artifact(mission.id, "design_#{s}")}
      end)

    review = GiTF.Missions.get_artifact(mission.id, "review")

    mode =
      if mission[:current_phase] in ["design", "review"] and
           (is_nil(review) or review["approved"] != true) do
        :approval
      else
        :view_only
      end

    # Open on Compare whenever there is something to compare. Landing on the
    # winner's tab skipped past the case for it — the file divergence, the
    # risks each strategy foresaw, and the review's own reasoning all live on
    # Compare now. A single strategy has no comparison to show, so it opens
    # straight to its detail.
    default_tab =
      if length(active_strategies) == 1, do: hd(active_strategies), else: "compare"

    active_tab = Map.get(socket.assigns, :active_tab, default_tab)

    socket
    |> assign(:mission, mission)
    |> assign(:mode, mode)
    |> assign(:designs, designs)
    |> assign(:strategy_list, active_strategies)
    |> assign(:review, review)
    |> assign(:active_tab, active_tab)
    |> assign(:report, GiTF.Major.DesignReport.get(mission.id))
    |> assign(
      :requirement_index,
      requirement_index(GiTF.Missions.get_artifact(mission.id, "requirements"))
    )
    |> assign_new(:report_generating, fn -> false end)
  end

  # -- Helpers ---------------------------------------------------------------

  defp winner?(strategy, review) do
    review && selected_strategy(review) == strategy
  end

  defp selected_strategy(review) when is_map(review),
    do: review["selected_design"] || @default_strategy

  defp selected_strategy(_), do: @default_strategy

  defp strategy_color(strategy), do: Map.get(@strategy_colors, strategy, "#8b949e")
end
