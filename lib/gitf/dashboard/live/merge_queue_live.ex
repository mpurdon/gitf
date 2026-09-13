defmodule GiTF.Dashboard.MergeQueueLive do
  @moduledoc """
  Merge queue visualization showing pending, active, and recent merges.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers
  import GiTF.Dashboard.Surface.Components
  import GiTF.Dashboard.Surface.Page

  @heartbeat_interval :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "sync:queue")
      Process.send_after(self(), :heartbeat, @heartbeat_interval)
    end

    {:ok, socket |> init_toasts() |> assign_data()}
  end

  @impl true
  def handle_info(:heartbeat, socket) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, assign_data(socket)}
  end

  # React to merge queue changes and link messages in real-time
  def handle_info({:link_received, link}, socket) do
    {:noreply, socket |> maybe_apply_toast(link) |> assign_data()}
  end

  def handle_info({:sync_queue_updated, _}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp assign_data(socket) do
    queue_status =
      try do
        GiTF.Sync.Queue.status()
      rescue
        _ -> %{pending: [], active: nil, completed: []}
      end

    pending =
      (queue_status[:pending] || [])
      |> Enum.map(fn
        {op_id, shell_id} -> enrich_merge_entry(op_id, shell_id, "pending")
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    active =
      case queue_status[:active] do
        {op_id, shell_id, _ref} -> enrich_merge_entry(op_id, shell_id, "merging")
        {op_id, shell_id} -> enrich_merge_entry(op_id, shell_id, "merging")
        _ -> nil
      end

    completed =
      (queue_status[:completed] || [])
      |> Enum.take(20)
      |> Enum.map(fn
        {op_id, outcome, ts} ->
          entry = enrich_merge_entry(op_id, nil, "completed")
          Map.merge(entry, %{outcome: outcome, completed_at: ts})

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    socket
    |> assign(:page_title, "Merge Queue")
    |> assign(:current_path, "/merges")
    |> assign(:pending, pending)
    |> assign(:active, active)
    |> assign(:completed, completed)
    |> assign(:pending_count, length(pending))
  end

  defp enrich_merge_entry(op_id, shell_id, status) do
    op = GiTF.Archive.get(:ops, op_id)

    mission =
      case op do
        %{mission_id: mid} -> GiTF.Archive.get(:missions, mid)
        _ -> nil
      end

    %{
      op_id: op_id,
      shell_id: shell_id,
      status: status,
      op_title: op && op[:title],
      mission_name: mission && (mission[:name] || short_id(mission.id)),
      mission_id: op && op[:mission_id]
    }
  rescue
    _ ->
      %{
        op_id: op_id,
        shell_id: shell_id,
        status: status,
        op_title: nil,
        mission_name: nil,
        mission_id: nil
      }
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
        name="Merge queue"
        sub="finished ops waiting their turn at the trunk — one at a time, in order"
      >
        <:badges>
          <.pill tone={if @active, do: :recon, else: :ok}>
            {if @active, do: "merging", else: "idle"}
          </.pill>
        </:badges>

        <:metrics>
          <.metric label="Merging" value={if @active, do: 1, else: 0} />
          <.metric
            label="Waiting"
            value={@pending_count}
            tone={if @pending_count > 0, do: :warn}
          />
          <.metric label="Done recently" value={length(@completed)} />
        </:metrics>

        <.section title="Merging now">
          <.rows empty={is_nil(@active) && "Nothing is merging. The queue is not blocked."}>
            <.row
              :if={@active}
              cols="minmax(0,1fr) 200px"
              to={"/dashboard/ops/#{@active.op_id}"}
              link={:navigate}
            >
              <.identity
                name={@active.op_title || short_id(@active.op_id)}
                id={@active.mission_name}
              />
              <span style="justify-self:end"><.pill tone={:recon}>in progress</.pill></span>
            </.row>
          </.rows>
        </.section>

        <.section title="Waiting">
          <:hint>in order — the next one merges when the current one lands</:hint>
          <.rows empty={@pending == [] && "Nothing is waiting."}>
            <.row
              :for={{entry, idx} <- Enum.with_index(@pending)}
              cols="36px minmax(0,1fr) 200px 110px"
              to={"/dashboard/ops/#{entry.op_id}"}
              link={:navigate}
            >
              <span class="dim">{idx + 1}</span>
              <.identity name={entry.op_title || short_id(entry.op_id)} id={entry.op_id} />
              <span class="dim">{entry.mission_name || "—"}</span>
              <span class="dim">{short_id(entry.shell_id || "—")}</span>
            </.row>
          </.rows>
        </.section>

        <.section title="Recently merged">
          <.rows empty={@completed == [] && "Nothing has merged yet."}>
            <.row
              :for={entry <- @completed}
              cols="minmax(0,1fr) 200px 110px 150px"
              to={"/dashboard/ops/#{entry.op_id}"}
              link={:navigate}
            >
              <.identity name={entry.op_title || short_id(entry.op_id)} id={entry.op_id} />
              <span class="dim">{entry.mission_name || "—"}</span>
              <span><.pill tone={outcome_tone(entry[:outcome])}>{entry[:outcome] || "?"}</.pill></span>
              <span class="dim">{format_timestamp(entry[:completed_at])}</span>
            </.row>
          </.rows>
        </.section>
      </.object>
    </.live_component>
    """
  end

  defp outcome_tone(:ok), do: :ok
  defp outcome_tone(:error), do: :crit
  defp outcome_tone(_), do: nil
end
