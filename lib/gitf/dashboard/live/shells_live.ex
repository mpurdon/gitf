defmodule GiTF.Dashboard.ShellsLive do
  @moduledoc """
  Shell (git worktree) management page with drift status,
  cleanup actions, and per-shell detail.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers
  import GiTF.Dashboard.Surface.Components
  import GiTF.Dashboard.Surface.Page

  @heartbeat_interval :timer.seconds(20)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    {:ok,
     socket
     |> assign(:filter, "active")
     |> assign(:checking_drift, false)
     |> init_toasts()
     |> assign_data()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter, status)
     |> assign_data()}
  end

  def handle_event("check_drift_all", _params, socket) do
    socket = assign(socket, :checking_drift, true)

    Task.start(fn ->
      GiTF.Drift.check_all_active()
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Drift check started...")
     |> assign(:checking_drift, false)
     |> assign_data()}
  end

  def handle_event("remove_shell", %{"id" => shell_id}, socket) do
    case GiTF.Shell.remove(shell_id, force: true) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shell #{short_id(shell_id)} removed")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("rebase_shell", %{"id" => shell_id}, socket) do
    case GiTF.Drift.maybe_auto_rebase(shell_id) do
      {:ok, :rebased} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shell #{short_id(shell_id)} rebased")
         |> assign_data()}

      {:ok, :skipped, reason} ->
        {:noreply, put_flash(socket, :info, "Skipped: #{reason}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rebase failed: #{inspect(reason)}")}
    end
  end

  defp assign_data(socket) do
    shells = GiTF.Archive.all(:shells)

    filtered =
      case socket.assigns.filter do
        "active" -> Enum.filter(shells, &(&1.status == "active"))
        "removed" -> Enum.filter(shells, &(&1.status == "removed"))
        _ -> shells
      end
      |> Enum.sort_by(&(&1[:created_at] || DateTime.utc_now()), {:desc, DateTime})

    # Enrich with ghost + op info
    enriched =
      Enum.map(filtered, fn shell ->
        ghost =
          case shell[:ghost_id] do
            nil -> nil
            gid -> GiTF.Archive.get(:ghosts, gid)
          end

        op =
          case ghost do
            %{op_id: oid} when not is_nil(oid) -> GiTF.Archive.get(:ops, oid)
            _ -> nil
          end

        drift =
          case shell[:drift_state] do
            nil -> :unknown
            d when is_atom(d) -> d
            d when is_binary(d) -> String.to_existing_atom(d)
            _ -> :unknown
          end

        Map.merge(shell, %{
          ghost: ghost,
          op: op,
          drift: drift
        })
      end)

    counts = %{
      active: Enum.count(shells, &(&1.status == "active")),
      removed: Enum.count(shells, &(&1.status == "removed")),
      total: length(shells)
    }

    socket
    |> assign(:page_title, "Shells")
    |> assign(:current_path, "/shells")
    |> assign(:shells, enriched)
    |> assign(:counts, counts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={GiTF.Dashboard.AppLayout}
      id="layout"
      current_path={@current_path}
      flash={@flash}
      toasts={@toasts}
    >
      <.object
        kind="Fleet"
        name="Shells"
        sub="one git worktree per working ghost — where the changes actually happen"
      >
        <:badges>
          <.pill tone={if @counts.active > 0, do: :recon, else: nil}>
            {@counts.active} active
          </.pill>
        </:badges>

        <:metrics>
          <.metric label="Active" value={@counts.active} />
          <.metric label="Removed" value={@counts.removed} />
          <.metric label="Ever" value={@counts.total} />
        </:metrics>

        <:actions>
          <button phx-click="check_drift_all" class="btn pri sm" disabled={@checking_drift}>
            {if @checking_drift, do: "Checking…", else: "Check drift on all"}
          </button>
          <%!-- Filters are buttons rather than links because this page keeps no
                scope in its URL; that is a shortcoming it shares with every
                collection page here, and the fix belongs to all of them. --%>
          <button
            :for={{label, key, count} <- [
              {"Active", "active", @counts.active},
              {"Removed", "removed", @counts.removed},
              {"All", "all", @counts.total}
            ]}
            phx-click="filter"
            phx-value-status={key}
            class={["chip", @filter == key && "on"]}
          >{label} {count}</button>
        </:actions>

        <.section title="Shells">
          <:hint>drift is how far a worktree has fallen behind the trunk</:hint>
          <.rows empty={
            @shells == [] &&
              "No shells. One is cut whenever a ghost starts work, and removed when it finishes."
          }>
            <div :for={shell <- @shells} class="row" style="grid-template-columns:190px 110px 130px minmax(0,1fr) 90px 84px 130px">
              <.identity
                name={short_id(shell.id)}
                id={shell[:worktree_path] && Path.basename(shell.worktree_path)}
              />
              <span class="dim">{short_id(shell[:sector_id] || "—")}</span>
              <span>
                <.link :if={shell.ghost} navigate="/dashboard/ghosts">
                  {short_id(shell.ghost.id)}
                </.link>
                <span :if={!shell.ghost} class="note">no ghost</span>
              </span>
              <span>
                <.link :if={shell.op} navigate={"/dashboard/ops/#{shell.op.id}"}>
                  {shell.op.title || short_id(shell.op.id)}
                </.link>
                <span :if={!shell.op} class="note">no op</span>
              </span>
              <span><.pill tone={tone(shell.drift)}>{shell.drift}</.pill></span>
              <span class="dim">{String.slice(shell[:base_commit_sha] || "—", 0, 7)}</span>
              <span style="justify-self:end;display:inline-flex;gap:6px">
                <button
                  :if={shell.status == "active" and shell.drift in [:behind, :risky]}
                  phx-click="rebase_shell"
                  phx-value-id={shell.id}
                  class="btn sm"
                >Rebase</button>
                <button
                  :if={shell.status == "active"}
                  phx-click="remove_shell"
                  phx-value-id={shell.id}
                  class="btn sm danger"
                  data-confirm="Remove this shell?"
                >Remove</button>
                <.pill :if={shell.status != "active"} tone={nil}>{shell.status}</.pill>
              </span>
            </div>
          </.rows>
        </.section>
      </.object>
    </.live_component>
    """
  end
end
