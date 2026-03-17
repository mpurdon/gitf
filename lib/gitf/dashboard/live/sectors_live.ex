defmodule GiTF.Dashboard.SectorsLive do
  @moduledoc "Sector management page with local discovery, GitHub import, and manual add."

  use Phoenix.LiveView

  import GiTF.Dashboard.Helpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sectors")
     |> assign(:current_path, "/sectors")
     |> assign(:sectors, load_sectors())
     |> assign(:current_sector, load_current())
     |> assign(:add_mode, "discover")
     |> assign(:new_path, "")
     |> assign(:new_name, "")
     |> assign(:discovered_repos, [])
     |> assign(:github_repos, [])
     |> assign(:github_loading, false)
     |> assign(:github_error, nil)
     |> assign(:has_github_token, has_github_token?())}
  end

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    socket =
      case mode do
        "discover" -> assign(socket, :discovered_repos, discover_local_repos())
        "github" -> socket
        "manual" -> socket
        _ -> socket
      end

    {:noreply, assign(socket, :add_mode, mode)}
  end

  def handle_event("discover", _params, socket) do
    {:noreply, assign(socket, :discovered_repos, discover_local_repos())}
  end

  def handle_event("add_discovered", %{"path" => path}, socket) do
    name = Path.basename(path)

    case GiTF.Sector.add(path, name: name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(sectors: load_sectors(), discovered_repos: discover_local_repos())
         |> put_flash(:info, "Sector \"#{name}\" added.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("load_github", _params, socket) do
    {:noreply, assign(socket, github_loading: true, github_error: nil)}
  end

  def handle_event("fetch_github", _params, socket) do
    case GiTF.GitHub.list_repos(per_page: 50) do
      {:ok, repos} ->
        # Filter out repos already registered as sectors
        existing_names = load_sectors() |> Enum.map(& &1.name) |> MapSet.new()

        repos =
          Enum.reject(repos, fn r ->
            MapSet.member?(existing_names, r.name)
          end)

        {:noreply, assign(socket, github_repos: repos, github_loading: false, github_error: nil)}

      {:error, :no_github_token} ->
        {:noreply,
         assign(socket,
           github_loading: false,
           github_error: "No GitHub token found. Set GITHUB_TOKEN or add [github] token to .gitf/config.toml"
         )}

      {:error, :unauthorized} ->
        {:noreply, assign(socket, github_loading: false, github_error: "GitHub token is invalid or expired.")}

      {:error, reason} ->
        {:noreply, assign(socket, github_loading: false, github_error: "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("add_github", %{"clone_url" => url, "name" => name, "owner" => owner, "repo" => repo_name}, socket) do
    opts = [name: name, github_owner: owner, github_repo: repo_name]

    case GiTF.Sector.add(url, opts) do
      {:ok, _} ->
        # Remove from github_repos list
        repos = Enum.reject(socket.assigns.github_repos, &(&1.name == name))

        {:noreply,
         socket
         |> assign(sectors: load_sectors(), github_repos: repos)
         |> put_flash(:info, "Sector \"#{name}\" added from GitHub.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clone: #{inspect(reason)}")}
    end
  end

  def handle_event("update_form", %{"path" => path, "name" => name}, socket) do
    {:noreply, assign(socket, new_path: path, new_name: name)}
  end

  def handle_event("add_manual", %{"path" => path, "name" => name}, socket) do
    path = String.trim(path)
    name = String.trim(name)

    if path == "" do
      {:noreply, put_flash(socket, :error, "Path or URL is required.")}
    else
      opts = if name != "", do: [name: name], else: []

      case GiTF.Sector.add(path, opts) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(sectors: load_sectors(), new_path: "", new_name: "")
           |> put_flash(:info, "Sector added.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, format_sector_error(reason, path))}
      end
    end
  end

  def handle_event("set_current", %{"id" => id}, socket) do
    case GiTF.Sector.set_current(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(sectors: load_sectors(), current_sector: load_current())
         |> put_flash(:info, "Current sector updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case GiTF.Sector.remove(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(sectors: load_sectors(), current_sector: load_current())
         |> put_flash(:info, "Sector removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  # Async handler for GitHub fetch
  @impl true
  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:github_repos, repos} ->
        {:noreply, assign(socket, github_repos: repos, github_loading: false)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Data ------------------------------------------------------------------

  defp load_sectors do
    try do
      GiTF.Sector.list()
    rescue
      _ -> []
    end
  end

  defp load_current do
    case GiTF.Sector.current() do
      {:ok, sector} -> sector
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp has_github_token? do
    System.get_env("GITHUB_TOKEN") != nil
  end

  defp discover_local_repos do
    # Look for git repos in the gitf workspace parent dir and common locations
    dirs =
      case GiTF.gitf_dir() do
        {:ok, root} -> [Path.dirname(root), root]
        _ -> [File.cwd!()]
      end

    existing_paths =
      load_sectors()
      |> Enum.map(& &1[:path])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    dirs
    |> Enum.flat_map(fn dir ->
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.filter(fn path -> File.dir?(Path.join(path, ".git")) end)
          |> Enum.reject(fn path -> MapSet.member?(existing_paths, path) end)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp format_sector_error(:path_not_found, path), do: "Directory not found: #{path}"
  defp format_sector_error(:name_already_taken, _), do: "A sector with that name already exists."
  defp format_sector_error(:not_a_git_repo, path), do: "#{path} is not a git repository."
  defp format_sector_error(reason, _), do: "Failed: #{inspect(reason)}"

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash}>
      <h1 class="page-title">Sectors</h1>

      <!-- Add sector panel with mode tabs -->
      <div class="panel" style="margin-bottom:1.5rem">
        <div class="panel-title">Add Sector</div>

        <!-- Mode tabs -->
        <div style="display:flex; gap:0.25rem; margin-bottom:1rem; border-bottom:1px solid #30363d; padding-bottom:0.5rem">
          <button
            phx-click="switch_mode" phx-value-mode="discover"
            class={"btn #{if @add_mode == "discover", do: "btn-blue", else: "btn-grey"}"}
            style="font-size:0.8rem; padding:0.3rem 0.75rem"
          >
            Browse Local
          </button>
          <button
            phx-click="switch_mode" phx-value-mode="github"
            class={"btn #{if @add_mode == "github", do: "btn-blue", else: "btn-grey"}"}
            style="font-size:0.8rem; padding:0.3rem 0.75rem"
          >
            GitHub
          </button>
          <button
            phx-click="switch_mode" phx-value-mode="manual"
            class={"btn #{if @add_mode == "manual", do: "btn-blue", else: "btn-grey"}"}
            style="font-size:0.8rem; padding:0.3rem 0.75rem"
          >
            Manual
          </button>
        </div>

        <!-- Discover local repos -->
        <%= if @add_mode == "discover" do %>
          <p style="color:#8b949e; font-size:0.8rem; margin-bottom:0.75rem">
            Git repositories found near the workspace. Click to add.
          </p>
          <button phx-click="discover" class="btn btn-grey" style="margin-bottom:0.75rem; font-size:0.8rem">
            Refresh
          </button>
          <%= if @discovered_repos == [] do %>
            <div class="empty">No new git repositories found nearby.</div>
          <% else %>
            <div style="display:flex; flex-direction:column; gap:0.35rem">
              <%= for path <- @discovered_repos do %>
                <div style="display:flex; align-items:center; justify-content:space-between; padding:0.5rem 0.75rem; background:#1c2128; border-radius:6px; border:1px solid #30363d">
                  <div>
                    <span style="color:#f0f6fc; font-weight:500">{Path.basename(path)}</span>
                    <span style="color:#8b949e; font-family:monospace; font-size:0.75rem; margin-left:0.5rem">{path}</span>
                  </div>
                  <button phx-click="add_discovered" phx-value-path={path} class="btn btn-green" style="padding:0.2rem 0.6rem; font-size:0.75rem">
                    Add
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <!-- GitHub repos -->
        <%= if @add_mode == "github" do %>
          <%= if @has_github_token do %>
            <p style="color:#8b949e; font-size:0.8rem; margin-bottom:0.75rem">
              Import a repository from your GitHub account. It will be cloned into the workspace.
            </p>

            <%= if @github_repos == [] and not @github_loading do %>
              <button phx-click="fetch_github" class="btn btn-blue" style="font-size:0.85rem">
                Load My Repositories
              </button>
            <% end %>

            <%= if @github_loading do %>
              <div style="color:#8b949e; padding:1rem">Loading repositories...</div>
            <% end %>

            <%= if @github_error do %>
              <div style="color:#f85149; padding:0.5rem 0; font-size:0.85rem">{@github_error}</div>
            <% end %>

            <%= if @github_repos != [] do %>
              <div style="display:flex; flex-direction:column; gap:0.35rem; max-height:400px; overflow-y:auto">
                <%= for repo <- @github_repos do %>
                  <div style="display:flex; align-items:center; justify-content:space-between; padding:0.5rem 0.75rem; background:#1c2128; border-radius:6px; border:1px solid #30363d">
                    <div style="flex:1; min-width:0">
                      <div style="display:flex; align-items:center; gap:0.5rem">
                        <span style="color:#f0f6fc; font-weight:500">{repo.name}</span>
                        <%= if repo.private do %>
                          <span class="badge badge-yellow" style="font-size:0.6rem">private</span>
                        <% end %>
                        <%= if repo.language do %>
                          <span class="badge badge-purple" style="font-size:0.6rem">{repo.language}</span>
                        <% end %>
                      </div>
                      <%= if repo.description do %>
                        <div style="color:#8b949e; font-size:0.75rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis">
                          {repo.description}
                        </div>
                      <% end %>
                    </div>
                    <button
                      phx-click="add_github"
                      phx-value-clone_url={repo.clone_url}
                      phx-value-name={repo.name}
                      phx-value-owner={String.split(repo.full_name, "/") |> List.first()}
                      phx-value-repo={repo.name}
                      class="btn btn-green"
                      style="padding:0.2rem 0.6rem; font-size:0.75rem; margin-left:0.5rem; white-space:nowrap"
                    >
                      Clone & Add
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% else %>
            <div style="color:#8b949e; padding:0.5rem 0; font-size:0.85rem">
              <p>Set <code style="color:#d2a8ff; background:#1c2128; padding:0.1rem 0.3rem; border-radius:3px">GITHUB_TOKEN</code> environment variable or add it to <code style="color:#d2a8ff; background:#1c2128; padding:0.1rem 0.3rem; border-radius:3px">.gitf/config.toml</code> to enable GitHub integration.</p>
              <pre style="margin-top:0.5rem; color:#c9d1d9; font-size:0.75rem; background:#161b22; padding:0.5rem; border-radius:4px">[github]
token = "ghp_your_token_here"</pre>
            </div>
          <% end %>
        <% end %>

        <!-- Manual path/URL -->
        <%= if @add_mode == "manual" do %>
          <p style="color:#8b949e; font-size:0.8rem; margin-bottom:0.75rem">
            Enter a local path to a git repository or a remote git URL to clone.
          </p>
          <form phx-submit="add_manual" phx-change="update_form" style="display:flex; gap:0.75rem; align-items:flex-end; flex-wrap:wrap">
            <div class="form-group" style="flex:2; margin-bottom:0; min-width:200px">
              <label class="form-label">Path or URL</label>
              <input type="text" name="path" class="form-input" placeholder="/path/to/repo or https://github.com/user/repo.git" value={@new_path} required />
            </div>
            <div class="form-group" style="flex:1; margin-bottom:0; min-width:120px">
              <label class="form-label">Name (optional)</label>
              <input type="text" name="name" class="form-input" placeholder="sector name" value={@new_name} />
            </div>
            <button type="submit" class="btn btn-green" style="margin-bottom:0">Add</button>
          </form>
        <% end %>
      </div>

      <!-- Existing sectors table -->
      <div class="panel">
        <div class="panel-title">Registered Sectors ({length(@sectors)})</div>
        <%= if @sectors == [] do %>
          <div class="empty">No sectors registered yet. Add one above to get started.</div>
        <% else %>
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Path</th>
                <th>Strategy</th>
                <th>GitHub</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for sector <- @sectors do %>
                <tr>
                  <td style="font-weight:500; color:#f0f6fc">
                    {Map.get(sector, :name, "-")}
                    <%= if @current_sector && Map.get(@current_sector, :id) == Map.get(sector, :id) do %>
                      <span class="badge badge-green" style="margin-left:0.5rem">current</span>
                    <% end %>
                  </td>
                  <td style="font-family:monospace; font-size:0.8rem; color:#8b949e">
                    {Map.get(sector, :path, "-")}
                  </td>
                  <td>{Map.get(sector, :sync_strategy, "-")}</td>
                  <td>
                    <%= if Map.get(sector, :github_owner) do %>
                      <a href={"https://github.com/#{sector.github_owner}/#{sector.github_repo}"} target="_blank" style="color:#58a6ff; font-size:0.8rem">
                        {sector.github_owner}/{sector.github_repo}
                      </a>
                    <% else %>
                      <span style="color:#6e7681">—</span>
                    <% end %>
                  </td>
                  <td style="text-align:right; white-space:nowrap">
                    <%= unless @current_sector && Map.get(@current_sector, :id) == Map.get(sector, :id) do %>
                      <button phx-click="set_current" phx-value-id={sector.id} class="btn btn-blue" style="padding:0.2rem 0.5rem; font-size:0.7rem; margin-right:0.25rem">
                        Set Current
                      </button>
                    <% end %>
                    <button phx-click="remove" phx-value-id={sector.id} class="btn btn-red" style="padding:0.2rem 0.5rem; font-size:0.7rem" data-confirm={"Remove sector #{sector.name}?"}>
                      Remove
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </.live_component>
    """
  end
end
