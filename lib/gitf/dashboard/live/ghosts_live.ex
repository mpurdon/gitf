defmodule GiTF.Dashboard.GhostsLive do
  @moduledoc """
  Ghost monitoring page.

  Displays all ghosts with their status, name, assigned op, and shell
  information. Subscribes to PubSub for live status updates. Working
  ghosts show a green pulse animation; crashed ghosts appear in red.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers
  import GiTF.Dashboard.Surface.Components
  import GiTF.Dashboard.Surface.Page

  require GiTF.Ghost.Status, as: GhostStatus

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    {:ok, socket |> assign(:refresh_scheduled, false) |> assign_data()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> schedule_refresh()}
  end

  # Debounced refresh: collapse rapid PubSub events into one reload 150ms out.
  def handle_info(:debounced_refresh, socket) do
    {:noreply, socket |> assign(:refresh_scheduled, false) |> assign_data()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(socket) do
    if !socket.assigns[:refresh_scheduled] do
      Process.send_after(self(), :debounced_refresh, 150)
    end

    assign(socket, :refresh_scheduled, true)
  end

  @impl true
  def handle_event("toggle", %{"id" => ghost_id}, socket) do
    expanded = Map.get(socket.assigns, :expanded, MapSet.new())

    expanded =
      if MapSet.member?(expanded, ghost_id),
        do: MapSet.delete(expanded, ghost_id),
        else: MapSet.put(expanded, ghost_id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("stop", %{"id" => ghost_id}, socket) do
    case GiTF.Ghosts.stop(ghost_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Ghost stopped.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  defp assign_data(socket) do
    ghosts = GiTF.Ghosts.list()

    # Enrich each ghost with op + mission links
    enriched =
      Enum.map(ghosts, fn ghost ->
        op =
          case ghost[:op_id] do
            nil -> nil
            oid -> GiTF.Archive.get(:ops, oid)
          end

        mission =
          case op do
            %{mission_id: mid} -> GiTF.Archive.get(:missions, mid)
            _ -> nil
          end

        shell =
          GiTF.Archive.find_one(:shells, fn s ->
            s[:ghost_id] == ghost.id and s.status == "active"
          end)

        Map.merge(ghost, %{
          op: op,
          mission: mission,
          shell: shell,
          drift: shell && (shell[:drift_state] || :unknown)
        })
      end)

    working = Enum.count(enriched, &(Map.get(&1, :status) == "working"))
    stopped = Enum.count(enriched, &(Map.get(&1, :status) in ["stopped", "crashed"]))
    total = length(enriched)

    socket =
      socket
      |> assign(:page_title, "Ghosts")
      |> assign(:current_path, "/ghosts")
      |> assign(:ghosts_empty?, enriched == [])
      |> assign(:ghosts_working, working)
      |> assign(:ghosts_stopped, stopped)
      |> assign(:ghosts_total, total)
      |> assign_new(:expanded, fn -> MapSet.new() end)
      |> init_toasts()

    if Map.has_key?(socket.assigns, :streams) and Map.has_key?(socket.assigns.streams, :ghosts) do
      stream(socket, :ghosts, enriched, reset: true)
    else
      socket
      |> stream_configure(:ghosts, dom_id: &"ghost-#{&1.id}")
      |> stream(:ghosts, enriched)
    end
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
        name="Ghosts"
        sub="the processes doing the work — one per op the Major has assigned"
      >
        <:badges>
          <.pill tone={if @ghosts_working > 0, do: :recon, else: nil}>
            {if @ghosts_working > 0, do: "#{@ghosts_working} working", else: "all quiet"}
          </.pill>
        </:badges>

        <:metrics>
          <.metric label="Working" value={@ghosts_working} tone={if @ghosts_working > 0, do: :ok} />
          <.metric label="Idle" value={@ghosts_total - @ghosts_working - @ghosts_stopped} />
          <.metric label="Stopped" value={@ghosts_stopped} tone={if @ghosts_stopped > 0, do: :crit} />
          <.metric label="Ever" value={@ghosts_total} />
        </:metrics>

        <.section title="Ghosts">
          <:hint>a full context window is why a ghost hands off — watch that column</:hint>

          <div :if={@ghosts_empty?} class="empty">
            No ghosts deployed yet. One is created whenever the Major assigns an op.
          </div>

          <div :if={!@ghosts_empty?} class="rows" id="ghosts-table" phx-update="stream">
            <div :for={{dom_id, ghost} <- @streams.ghosts} id={dom_id}>
              <div class="row" style="grid-template-columns:18px 150px 120px minmax(0,1fr) 96px 90px 70px">
                <.dot tone={tone(Map.get(ghost, :status))} />
                <.identity
                  name={ghost_badge_label(Map.get(ghost, :name, "-"), ghost[:assigned_model])}
                  id={short_id(ghost.id)}
                />
                <span><.pill tone={tone(Map.get(ghost, :status))}>{Map.get(ghost, :status, "unknown")}</.pill></span>
                <span>
                  <.link :if={ghost.op} navigate={"/dashboard/ops/#{ghost.op.id}"}>
                    {ghost.op[:title] || short_id(ghost.op.id)}
                  </.link>
                  <span :if={!ghost.op} class="note">no op</span>
                  <br :if={ghost.mission} /><.link
                    :if={ghost.mission}
                    navigate={"/dashboard/missions/#{ghost.mission.id}"}
                    class="note"
                  >{Map.get(ghost.mission, :name) || short_id(ghost.mission.id)}</.link>
                </span>
                <%!-- A ghost that never ran has 0% context, and 0% in green
                      reads as "healthy" for something that did nothing. Only a
                      window that has been used says anything. --%>
                <span>
                  <.pill :if={used_context?(ghost)} tone={context_tone(ghost.context_percentage)}>
                    {Float.round(ghost.context_percentage / 1, 1)}%
                  </.pill>
                  <span :if={!used_context?(ghost)} class="note">—</span>
                </span>
                <span>
                  <.pill :if={ghost.drift} tone={tone(ghost.drift)}>{ghost.drift}</.pill>
                  <span :if={!ghost.drift} class="note">—</span>
                </span>
                <span style="justify-self:end">
                  <button
                    :if={Map.get(ghost, :status) == GhostStatus.working()}
                    phx-click="stop"
                    phx-value-id={ghost.id}
                    class="btn sm danger"
                  >Stop</button>
                </span>
              </div>
            </div>
          </div>
        </.section>
      </.object>
    </.live_component>
    """
  end

  defp used_context?(ghost), do: (ghost[:context_percentage] || 0) > 0

  # A ghost hands off when its window fills, so the threshold is the fact worth
  # colouring — not the percentage itself.
  defp context_tone(percentage) when percentage >= 45, do: :crit
  defp context_tone(percentage) when percentage >= 40, do: :warn
  defp context_tone(_), do: :ok
end
