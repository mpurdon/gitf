defmodule GiTF.Dashboard.ShellsLive do
  @moduledoc """
  Shell (git worktree) management page with drift status,
  cleanup actions, and per-shell detail.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  import GiTF.Dashboard.Helpers

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "link:major")
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    {:ok,
     socket
     |> assign(:filter, "active")
     |> assign(:checking_drift, false)
     |> init_toasts()
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
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

  defp drift_badge(:clean), do: "badge-green"
  defp drift_badge(:behind), do: "badge-yellow"
  defp drift_badge(:risky), do: "badge-orange"
  defp drift_badge(:conflicted), do: "badge-red"
  defp drift_badge(_), do: "badge-grey"

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <h1 class="page-title" style="margin-bottom:0">Shells & Worktrees</h1>
        <div style="display:flex; gap:0.5rem">
          <button phx-click="check_drift_all" class="btn btn-blue" style="font-size:0.8rem" disabled={@checking_drift}>
            {if @checking_drift, do: "Checking...", else: "Check Drift (All)"}
          </button>
        </div>
      </div>

      <%!-- Filter tabs --%>
      <div style="display:flex; gap:0.5rem; margin-bottom:1rem">
        <%= for {label, key, count} <- [{"Active", "active", @counts.active}, {"Removed", "removed", @counts.removed}, {"All", "all", @counts.total}] do %>
          <button
            phx-click="filter"
            phx-value-status={key}
            class={"btn #{if @filter == key, do: "btn-blue", else: "btn-grey"}"}
            style="font-size:0.8rem; padding:0.3rem 0.6rem"
          >
            {label} <span style="opacity:0.6; margin-left:0.25rem">({count})</span>
          </button>
        <% end %>
      </div>

      <%= if @shells == [] do %>
        <div class="panel"><div class="empty">No shells found. Shells (git worktrees) are created when ghosts start working. <a href="/dashboard/missions" style="color:#58a6ff">Start a mission</a> to see shells appear here.</div></div>
      <% else %>
        <div class="panel">
          <table class="table" style="width:100%">
            <thead>
              <tr>
                <th>Shell</th>
                <th>Sector</th>
                <th>Ghost</th>
                <th>Op</th>
                <th>Drift</th>
                <th>Base Commit</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for shell <- @shells do %>
                <tr>
                  <td>
                    <span style="color:#58a6ff; font-family:monospace; font-size:0.8rem" title={shell.id}>
                      {short_id(shell.id)}
                    </span>
                    <div style="font-size:0.7rem; color:#6b7280; max-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap" title={shell[:worktree_path]}>
                      {shell[:worktree_path] && Path.basename(shell.worktree_path)}
                    </div>
                  </td>
                  <td style="font-size:0.8rem; color:#8b949e">{short_id(shell[:sector_id] || "-")}</td>
                  <td>
                    <%= if shell.ghost do %>
                      <a href={"/dashboard/ghosts"} style="color:#58a6ff; font-size:0.8rem">{short_id(shell.ghost.id)}</a>
                    <% else %>
                      <span style="color:#6b7280; font-size:0.8rem">-</span>
                    <% end %>
                  </td>
                  <td>
                    <%= if shell.op do %>
                      <a href={"/dashboard/ops/#{shell.op.id}"} style="color:#58a6ff; font-size:0.8rem" title={shell.op.title}>
                        {String.slice(shell.op.title || "", 0, 25)}
                      </a>
                    <% else %>
                      <span style="color:#6b7280; font-size:0.8rem">-</span>
                    <% end %>
                  </td>
                  <td>
                    <span class={"badge #{drift_badge(shell.drift)}"} style="font-size:0.7rem">
                      {shell.drift}
                    </span>
                  </td>
                  <td>
                    <span style="font-family:monospace; font-size:0.75rem; color:#8b949e">
                      {String.slice(shell[:base_commit_sha] || "-", 0, 7)}
                    </span>
                  </td>
                  <td>
                    <span class={"badge #{if shell.status == "active", do: "badge-green", else: "badge-grey"}"} style="font-size:0.7rem">
                      {shell.status}
                    </span>
                  </td>
                  <td>
                    <div style="display:flex; gap:0.25rem">
                      <%= if shell.status == "active" and shell.drift in [:behind, :risky] do %>
                        <button phx-click="rebase_shell" phx-value-id={shell.id} class="btn btn-blue" style="font-size:0.65rem; padding:0.15rem 0.4rem">
                          Rebase
                        </button>
                      <% end %>
                      <%= if shell.status == "active" do %>
                        <button
                          phx-click="remove_shell"
                          phx-value-id={shell.id}
                          class="btn btn-red"
                          style="font-size:0.65rem; padding:0.15rem 0.4rem"
                          data-confirm="Remove this shell?"
                        >
                          Remove
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.live_component>
    """
  end
end
