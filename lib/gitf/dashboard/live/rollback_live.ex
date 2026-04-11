defmodule GiTF.Dashboard.RollbackLive do
  @moduledoc """
  Rollback management page. Shows missions that can be reverted
  (have merge artifacts), and allows triggering safe rollback via
  `git revert -m 1`.
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

    {:ok, socket |> init_toasts() |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("revert", %{"id" => mission_id}, socket) do
    case GiTF.Rollback.revert_merge(mission_id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reverted merge for #{short_id(mission_id)}: #{result[:revert_sha] || "success"}")
         |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rollback failed: #{inspect(reason)}")}
    end
  end

  defp assign_data(socket) do
    # Find all missions with sync artifacts (completed merges)
    missions = GiTF.Missions.list()

    revertible =
      missions
      |> Enum.map(fn m ->
        sync_artifact = GiTF.Missions.get_artifact(m.id, "sync")
        revert_status = safe_revert_status(m.id)

        case sync_artifact do
          %{"merge_commit_sha" => sha} when is_binary(sha) ->
            %{
              mission: m,
              merge_sha: sha,
              main_before: sync_artifact["main_before_sha"],
              merged_at: sync_artifact["merged_at"],
              branch: sync_artifact["branch"],
              revertible: sync_artifact["revertible"] == true,
              revert_status: revert_status
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn r -> r.merged_at || "" end, :desc)

    socket
    |> assign(:page_title, "Rollback")
    |> assign(:current_path, "/rollback")
    |> assign(:revertible, revertible)
  end

  defp safe_revert_status(mission_id) do
    GiTF.Rollback.revert_status(mission_id)
  rescue
    _ -> :unknown
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <h1 class="page-title">Rollback Management</h1>

      <p style="color:#8b949e; font-size:0.85rem; margin-bottom:1.5rem">
        Safely revert merged missions via <code style="color:#c9d1d9">git revert -m 1</code>.
        This creates a new commit that undoes the merge — no force push, no history rewrite.
      </p>

      <%= if @revertible == [] do %>
        <div class="panel"><div class="empty">No merged missions found.</div></div>
      <% else %>
        <div class="panel">
          <table class="table" style="width:100%">
            <thead>
              <tr>
                <th>Mission</th>
                <th>Branch</th>
                <th>Merge SHA</th>
                <th>Merged At</th>
                <th>Status</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @revertible do %>
                <tr>
                  <td>
                    <a href={"/dashboard/missions/#{entry.mission.id}"} style="color:#58a6ff; font-size:0.85rem">
                      {Map.get(entry.mission, :name) || short_id(entry.mission.id)}
                    </a>
                    <div style="font-size:0.7rem; color:#6b7280">
                      {Map.get(entry.mission, :status, "?")}
                    </div>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem; color:#c9d1d9">
                    {entry.branch || "-"}
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem; color:#8b949e">
                    {String.slice(entry.merge_sha, 0, 7)}
                  </td>
                  <td style="font-size:0.8rem; color:#8b949e">
                    {entry.merged_at || "-"}
                  </td>
                  <td>
                    <span class={"badge #{case entry.revert_status do
                      :reverted -> "badge-red"
                      :not_reverted -> "badge-green"
                      _ -> "badge-grey"
                    end}"} style="font-size:0.7rem">
                      {entry.revert_status}
                    </span>
                  </td>
                  <td>
                    <%= if entry.revertible and entry.revert_status != :reverted do %>
                      <button
                        phx-click="revert"
                        phx-value-id={entry.mission.id}
                        class="btn btn-red"
                        style="font-size:0.75rem; padding:0.25rem 0.5rem"
                        data-confirm="Revert this merge? A new commit will be created."
                      >
                        Revert
                      </button>
                    <% else %>
                      <span style="color:#6b7280; font-size:0.75rem">
                        {if entry.revert_status == :reverted, do: "already reverted", else: "not revertible"}
                      </span>
                    <% end %>
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
