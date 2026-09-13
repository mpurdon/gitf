defmodule GiTF.Dashboard.OpDetailLive do
  @moduledoc """
  One op, at whatever depth you asked for.

  An op is the smallest unit of work the factory schedules, and the question
  about one is almost always "what is it doing, and if it went wrong, why". So
  Overview is that; Evidence is everything the op produced and every attempt it
  took; Raw is the record, because the simplified view must never be a dead end.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers
  import GiTF.Dashboard.Surface.Components
  import GiTF.Dashboard.Surface.Page

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    case GiTF.Ops.get(id) do
      {:ok, op} ->
        {:ok,
         socket
         |> assign(:page_title, Map.get(op, :title, "Op"))
         |> assign(:current_path, "/ops")
         |> assign(:op, op)
         |> assign(:refresh_scheduled, false)
         |> assign_extras(op)
         |> assign_siblings(op)
         |> init_toasts()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Op not found.")
         |> push_navigate(to: "/dashboard/missions")}
    end
  end

  # Depth is a query parameter, so a link to an op's evidence is a link you can
  # send to someone.
  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, :tab, params["t"])}

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:link_received, link}, socket),
    do: {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}

  # Debounced refresh: collapse rapid PubSub events into one reload 150ms out.
  def handle_info(:debounced_refresh, socket) do
    {:noreply, socket |> assign(:refresh_scheduled, false) |> reload()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  @impl true
  def handle_event("reset", _params, socket) do
    case GiTF.Ops.reset(socket.assigns.op.id, nil) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Op reset.") |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  def handle_event("kill", _params, socket) do
    case GiTF.Ops.kill(socket.assigns.op.id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Op killed.") |> reload()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Kill failed: #{inspect(reason)}")}
    end
  end

  defp reload(socket) do
    case GiTF.Ops.get(socket.assigns.op.id) do
      {:ok, op} -> socket |> assign(:op, op) |> assign_extras(op) |> assign_siblings(op)
      {:error, _} -> socket
    end
  end

  defp assign_siblings(socket, op) do
    all_ops =
      GiTF.Archive.all(:ops)
      |> Enum.sort_by(& &1[:inserted_at], {:asc, DateTime})

    idx = Enum.find_index(all_ops, &(&1.id == op.id))

    prev_op = if idx && idx > 0, do: Enum.at(all_ops, idx - 1)
    next_op = if idx, do: Enum.at(all_ops, idx + 1)

    socket
    |> assign(:prev_op, prev_op)
    |> assign(:next_op, next_op)
  end

  defp assign_extras(socket, op) do
    # Retry chain: walk retry_of → parent, retried_as → children
    retry_chain = build_retry_chain(op)

    # Ghost info
    ghost =
      case op[:ghost_id] do
        nil -> nil
        gid -> GiTF.Archive.get(:ghosts, gid)
      end

    # Shell info
    shell =
      case ghost do
        nil ->
          nil

        g ->
          GiTF.Archive.find_one(:shells, fn s ->
            s[:ghost_id] == g.id and s.status == "active"
          end)
      end

    mission =
      case op[:mission_id] do
        nil -> nil
        mid -> GiTF.Archive.get(:missions, mid)
      end

    socket
    |> assign(:retry_chain, retry_chain)
    |> assign(:ghost, ghost)
    |> assign(:shell, shell)
    |> assign(:mission, mission)
  end

  defp build_retry_chain(op) do
    # Walk backwards to find root
    root = find_retry_root(op)
    # Walk forwards to build chain
    build_chain_forward(root, [])
  end

  defp find_retry_root(op) do
    case op[:retry_of] do
      nil ->
        op

      parent_id ->
        case GiTF.Archive.get(:ops, parent_id) do
          nil -> op
          parent -> find_retry_root(parent)
        end
    end
  rescue
    _ -> op
  end

  defp build_chain_forward(op, acc) do
    entry = %{
      id: op.id,
      status: op.status,
      title: op[:title],
      retry_strategy: op[:retry_strategy],
      retry_count: op[:retry_count] || 0
    }

    acc = [entry | acc]

    case op[:retried_as] do
      nil ->
        Enum.reverse(acc)

      next_id ->
        case GiTF.Archive.get(:ops, next_id) do
          nil -> Enum.reverse(acc)
          next -> build_chain_forward(next, acc)
        end
    end
  rescue
    _ -> Enum.reverse(acc)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:tab, assigns[:tab] || "overview")
      |> assign(:failed?, Map.get(assigns.op, :status) == "failed")

    ~H"""
    <.live_component
      module={GiTF.Dashboard.AppLayout}
      id="layout"
      current_path={@current_path}
      flash={@flash}
      toasts={@toasts}
    >
      <.object
        kind="Op"
        name={Map.get(@op, :title) || "Op"}
        sub={one_line(Map.get(@op, :description))}
        crumbs={crumbs(@op, @mission)}
        tabs={depths("/dashboard/ops/#{@op.id}", @tab, standard_depths())}
      >
        <:badges>
          <.pill tone={tone(Map.get(@op, :status))}>{Map.get(@op, :status) || "unknown"}</.pill>
          <%!-- "pending" twice, unlabelled, reads as one fact stuttered. --%>
          <.pill :if={Map.get(@op, :verification_status)} tone={tone(@op.verification_status)}>
            verification {@op.verification_status}
          </.pill>
          <span class="mono" style="font-size:var(--t-sm);color:var(--ink-3)">{@op.id}</span>
        </:badges>

        <:metrics>
          <.metric label="Type" value={Map.get(@op, :type) || "—"} />
          <.metric label="Phase" value={Map.get(@op, :phase) || "—"} />
          <.metric label="Model" value={Map.get(@op, :model) || "—"} />
          <%!-- This op's own position in the retry chain, not a count of the
                chain: `retry_count` is a counter on the record and the chain is
                walked through retry_of/retried_as, and the two disagree when a
                link is missing. Showing the counter as "attempts" made the head
                contradict the Evidence tab. --%>
          <.metric
            label="Attempt"
            value={"##{Map.get(@op, :retry_count) || 0}"}
            tone={if (Map.get(@op, :retry_count) || 0) > 0, do: :warn}
          />
        </:metrics>

        <:actions>
          <button :if={@failed?} phx-click="reset" class="btn pri sm">Reset</button>
          <button
            :if={Map.get(@op, :status) in ["active", "running", "assigned"]}
            phx-click="kill"
            class="btn sm danger"
            data-confirm="Kill this op?"
          >
            Kill
          </button>
          <.link :if={@prev_op} navigate={"/dashboard/ops/#{@prev_op.id}"} class="btn sm">
            ← Prev
          </.link>
          <.link :if={@next_op} navigate={"/dashboard/ops/#{@next_op.id}"} class="btn sm">
            Next →
          </.link>
        </:actions>

        <.overview :if={@tab == "overview"} op={@op} ghost={@ghost} shell={@shell} failed?={@failed?} />
        <.evidence :if={@tab == "evidence"} op={@op} retry_chain={@retry_chain} />
        <.record
          :if={@tab == "raw"}
          term={@op}
          note="The op record as the Archive holds it."
        />
      </.object>
    </.live_component>
    """
  end

  # A crumb trail only goes up as far as the page actually knows: an op with no
  # mission recorded gets two crumbs, not a broken link to nowhere.
  defp crumbs(op, mission) do
    [{"Missions", "/dashboard/missions"}] ++
      case op[:mission_id] do
        nil ->
          []

        id ->
          [{(mission && Map.get(mission, :name)) || short_id(id), "/dashboard/missions/#{id}"}]
      end ++ [{Map.get(op, :title) || "Op", "/dashboard/ops/#{op.id}"}]
  end

  attr(:op, :map, required: true)
  attr(:ghost, :any, default: nil)
  attr(:shell, :any, default: nil)
  attr(:failed?, :boolean, required: true)

  defp overview(assigns) do
    ~H"""
    <%!-- A failed op is here to be understood, so its reason comes before its
          metadata rather than eight panels below it. --%>
    <.section :if={@failed?} title="Why it failed">
      <.banner tone={:crit}>
        {Map.get(@op, :error_message) || "No error message was recorded."}
      </.banner>
      <p :if={no_failure_detail?(@op)} class="note" style="margin:var(--s3) 0 0">
        Nothing else was recorded. The
        <.link navigate={"/dashboard/missions/#{@op[:mission_id]}/diagnostics"}>
          mission diagnostics
        </.link>
        may know more.
      </p>
    </.section>

    <.section :if={Map.get(@op, :description)} title="What it was asked to do">
      <pre class="raw" style="max-height:22rem">{@op.description}</pre>
    </.section>

    <.section :if={Map.get(@op, :acceptance_criteria)} title="What would make it done">
      <:hint :if={Map.get(@op, :verification_status)}>
        verification {@op.verification_status}
      </:hint>
      <.rows>
        <.row
          :for={criterion <- List.wrap(@op.acceptance_criteria)}
          cols="22px minmax(0,1fr)"
        >
          <span style={"color:var(--#{if Map.get(@op, :verification_status) == "passed", do: "ok", else: "ink-3"})"}>
            {if Map.get(@op, :verification_status) == "passed", do: "✓", else: "○"}
          </span>
          <span>{criterion}</span>
        </.row>
      </.rows>
    </.section>

    <.section title="Who is doing it">
      <.rows empty={is_nil(@ghost) && "No ghost is assigned to this op."}>
        <.row :if={@ghost} cols="170px minmax(0,1fr)">
          <.identity name="Ghost" id="the process running this op" />
          <span class="dim">
            {short_id(@ghost.id)} · {Map.get(@ghost, :assigned_model) || "no model"}
          </span>
        </.row>
        <.row :if={@ghost} cols="170px minmax(0,1fr)">
          <.identity name="Context used" id="how full its window is" />
          <span class="dim">
            {Float.round((Map.get(@ghost, :context_percentage, 0.0) || 0.0) * 100, 1)}%
          </span>
        </.row>
        <.row :if={@shell} cols="170px minmax(0,1fr)">
          <.identity name="Worktree" id="where it is working" />
          <span class="dim">{@shell[:worktree_path] && Path.basename(@shell.worktree_path)}</span>
        </.row>
        <.row :if={@shell} cols="170px minmax(0,1fr)">
          <.identity name="Drift" id="how far the worktree is from the trunk" />
          <span><.pill tone={tone(@shell[:drift_state])}>{@shell[:drift_state] || "unknown"}</.pill></span>
        </.row>
      </.rows>
    </.section>

    <.section title="Where it sits">
      <.rows>
        <.row cols="170px minmax(0,1fr)">
          <.identity name="Complexity" id="what the planner judged" />
          <span class="dim">{Map.get(@op, :complexity) || "—"}</span>
        </.row>
        <.row cols="170px minmax(0,1fr)">
          <.identity name="Risk" id="what it could break" />
          <span class="dim">{Map.get(@op, :risk_level) || "—"}</span>
        </.row>
      </.rows>
    </.section>

    <.relations>
      <:rel verb="part of" to={@op[:mission_id] && "/dashboard/missions/#{@op.mission_id}"}>
        {(@op[:mission_id] && short_id(@op.mission_id)) || "no mission"}
      </:rel>
      <:rel :if={@op[:ghost_id]} verb="run by" to="/dashboard/ghosts">
        {short_id(@op.ghost_id)}
      </:rel>
    </.relations>
    """
  end

  attr(:op, :map, required: true)
  attr(:retry_chain, :list, required: true)

  defp evidence(assigns) do
    ~H"""
    <.section :if={length(@retry_chain) > 1} title="Attempts">
      <:hint>{length(@retry_chain)} in this chain · newest last</:hint>
      <.rows>
        <.row
          :for={entry <- @retry_chain}
          cols="60px minmax(0,1fr) 140px 96px"
          to={"/dashboard/ops/#{entry.id}"}
          link={:navigate}
        >
          <span class="dim">#{entry.retry_count}</span>
          <.identity name={entry.title || entry.id} id={entry.id} />
          <span class="dim">{entry.retry_strategy || "first attempt"}</span>
          <span style="justify-self:end"><.pill tone={tone(entry.status)}>{entry.status}</.pill></span>
        </.row>
      </.rows>
    </.section>

    <.section :if={Map.get(@op, :output_summary)} title="What the ghost reported">
      <pre class="raw">{@op.output_summary}</pre>
    </.section>

    <.section :if={Map.get(@op, :target_files) not in [nil, []]} title="Files it was to touch">
      <.rows>
        <.row :for={file <- List.wrap(@op.target_files)} cols="minmax(0,1fr)">
          <span class="mono" style="color:var(--accent)">{file}</span>
        </.row>
      </.rows>
    </.section>

    <.section :if={Map.get(@op, :verification_result)} title="Verification">
      <.record term={@op.verification_result} />
    </.section>

    <.section :if={Map.get(@op, :audit_result)} title="Audit">
      <pre class="raw">{@op.audit_result}</pre>
    </.section>

    <.section :if={Map.get(@op, :failure_info)} title="Failure analysis">
      <.record term={@op.failure_info} />
    </.section>

    <p :if={nothing_to_show?(@op, @retry_chain)} class="empty">
      This op produced no output, no verification and no audit — it has not run yet,
      or it was reset.
    </p>
    """
  end

  # The head's sub is one line. A description that is really a prompt gets its
  # first sentence here and all of itself in the body.
  defp one_line(nil), do: nil

  defp one_line(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp no_failure_detail?(op) do
    is_nil(op[:error_message]) and is_nil(op[:failure_info]) and is_nil(op[:audit_result])
  end

  defp nothing_to_show?(op, retry_chain) do
    length(retry_chain) <= 1 and
      Enum.all?(
        [:output_summary, :target_files, :verification_result, :audit_result, :failure_info],
        &(op[&1] in [nil, []])
      )
  end
end
