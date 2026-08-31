defmodule GiTF.Dashboard.CabinetLive do
  @moduledoc """
  The Cabinet page: the fleet at a glance, the inbox, the modes.

  Phone-first over tailscale: every ministry with its box state, wake and
  stop buttons, the mode switch, and the queued events waiting for the
  operator's "start this".
  """
  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  alias GiTF.Cabinet.{Fleet, Gate, Registry}

  @refresh :timer.seconds(20)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh)

    {:ok,
     socket
     |> assign(:page_title, "Cabinet")
     |> assign(:current_path, "/cabinet")
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
  def handle_event("wake", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.wake(ministry) do
      {:noreply,
       socket |> put_flash(:info, "Waking #{ministry.slug} — healthy in ~60-90s.") |> load()}
    else
      other -> {:noreply, put_flash(socket, :error, "Wake failed: #{inspect(other)}")}
    end
  end

  def handle_event("stop", %{"id" => id}, socket) do
    with %{} = ministry <- Registry.get(id), :ok <- Fleet.stop(ministry) do
      {:noreply, socket |> put_flash(:info, "Stopping #{ministry.slug}.") |> load()}
    else
      other -> {:noreply, put_flash(socket, :error, "Stop failed: #{inspect(other)}")}
    end
  end

  def handle_event("set_mode", %{"id" => id, "mode" => mode}, socket) do
    case Registry.set_mode(id, mode) do
      {:ok, m} -> {:noreply, socket |> put_flash(:info, "#{m.slug} → #{mode}") |> load()}
      other -> {:noreply, put_flash(socket, :error, "Mode change failed: #{inspect(other)}")}
    end
  end

  def handle_event("start_entry", %{"id" => id}, socket) do
    case Gate.start_queued(id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Waking the Section and forwarding.") |> load()}

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

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <h1 class="page-title">Cabinet</h1>

      <div class="panel">
        <div class="panel-title">Ministries</div>
        <div :if={@ministries == []} class="triage-warn">
          No ministries registered. Register one over MCP or the console.
        </div>
        <div :for={m <- @ministries} style="display:flex; align-items:center; gap:0.75rem; padding:0.6rem 0.25rem; border-bottom:1px solid #21262d; flex-wrap:wrap">
          <div style="min-width:9rem">
            <div style="font-weight:600; color:#f0f6fc">{m.name}</div>
            <div style="font-family:monospace; font-size:0.72rem; color:#8b949e">{m.slug}</div>
          </div>
          <span class={"badge #{if m.box_state == "running", do: "badge-green", else: "badge-grey"}"}>
            {m.box_state}
          </span>
          <span class={"badge #{mode_badge(m.mode)}"}>{m.mode}</span>
          <span class="spacer" style="flex:1"></span>
          <button :for={mode <- ~w(normal vacation off)} :if={m.mode != mode}
            phx-click="set_mode" phx-value-id={m.id} phx-value-mode={mode} class="btn btn-grey"
            style="font-size:0.72rem">{mode}</button>
          <button :if={m.box_state != "running"} phx-click="wake" phx-value-id={m.id} class="btn btn-green">Wake</button>
          <button :if={m.box_state == "running"} phx-click="stop" phx-value-id={m.id} class="btn btn-red">Stop</button>
          <a :if={m.url} href={m.url} target="_blank" style="font-size:0.75rem; color:#58a6ff">open ↗</a>
        </div>
      </div>

      <div class="panel">
        <div class="panel-title">Inbox</div>
        <div :if={@inbox == []} style="color:#8b949e; font-size:0.85rem">Nothing waiting on you.</div>
        <div :for={e <- @inbox} style="display:flex; align-items:center; gap:0.6rem; padding:0.5rem 0.25rem; border-bottom:1px solid #21262d; flex-wrap:wrap">
          <span class="badge badge-grey" style="font-family:monospace">{e.ministry_slug}</span>
          <span class={"badge #{class_badge(e.class)}"}>{e.class}</span>
          <span style="flex:1; min-width:12rem; font-size:0.85rem; color:#c9d1d9">{e.summary}</span>
          <span class="badge badge-grey" style="font-size:0.65rem">{e.status}</span>
          <button :if={e.status == "queued"} phx-click="start_entry" phx-value-id={e.id} class="btn btn-green" style="font-size:0.75rem">
            start this
          </button>
        </div>
      </div>
    </.live_component>
    """
  end

  defp mode_badge("vacation"), do: "badge-orange"
  defp mode_badge("off"), do: "badge-red"
  defp mode_badge(_), do: "badge-green"

  defp class_badge("bug"), do: "badge-red"
  defp class_badge("pr_review"), do: "badge-purple"
  defp class_badge("feature"), do: "badge-orange"
  defp class_badge(_), do: "badge-grey"
end
