defmodule GiTF.Dashboard.WorkflowsLive do
  @moduledoc """
  Workflow list page.

  Shows every workflow visible to the current operator: globals from
  `<vault>/Workflows/`, sector-scoped overrides from
  `<vault>/Sectors/<id>/Workflows/`, and the bundled defaults under
  `priv/workflows/`. Each entry links to the visual editor.
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Workflows")
     |> assign(:current_path, "/workflows")
     |> assign(:workflows, GiTF.Workflow.list())
     |> assign(:show_new_form, false)
     |> assign(:new_name, "")
     |> assign(:new_template, "standard")
     |> assign(:new_sector, "")
     |> assign(:sectors, list_sectors())
     |> init_toasts()}
  end

  @impl true
  def handle_event("toggle_new", _params, socket) do
    {:noreply, assign(socket, :show_new_form, !socket.assigns.show_new_form)}
  end

  def handle_event("update_new", %{"name" => name, "template" => tmpl, "sector" => sec}, socket) do
    {:noreply,
     socket
     |> assign(:new_name, name)
     |> assign(:new_template, tmpl)
     |> assign(:new_sector, sec)}
  end

  def handle_event("create_workflow", _params, socket) do
    name = String.trim(socket.assigns.new_name)
    template = socket.assigns.new_template
    sector = blank_to_nil(socket.assigns.new_sector)

    cond do
      name == "" ->
        {:noreply, push_toast(socket, "Workflow name is required", :error)}

      not Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) ->
        {:noreply,
         push_toast(socket, "Name must be lowercase letters, digits, and hyphens", :error)}

      true ->
        create_from_template(socket, name, template, sector)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
        <div>
          <h1 class="page-title" style="margin:0">Workflows</h1>
          <p style="color:var(--muted); font-size:0.85rem; margin:0.5rem 0 0 0">
            Declarative mission pipelines. Edit phases, branching, and gates without touching code.
          </p>
        </div>
        <button class="btn btn-blue" phx-click="toggle_new">
          <%= if @show_new_form, do: "× Cancel", else: "+ New workflow" %>
        </button>
      </div>

      <%= if @show_new_form do %>
        <div class="panel" style="margin-bottom:1.5rem">
          <div class="panel-title">Create workflow</div>
          <form phx-change="update_new" phx-submit="create_workflow">
            <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:0.75rem; margin-bottom:0.75rem">
              <div>
                <label style="display:block; color:var(--muted); font-size:0.75rem; margin-bottom:0.25rem; text-transform:uppercase">Name</label>
                <input
                  type="text"
                  name="name"
                  value={@new_name}
                  placeholder="my-workflow"
                  pattern="[a-z0-9][a-z0-9\-]*"
                  style="width:100%; background:var(--ground); border:1px solid var(--line); color:var(--text-2); padding:0.4rem 0.6rem; border-radius:4px; font-size:0.85rem"
                />
              </div>
              <div>
                <label style="display:block; color:var(--muted); font-size:0.75rem; margin-bottom:0.25rem; text-transform:uppercase">Fork from</label>
                <select
                  name="template"
                  style="width:100%; background:var(--ground); border:1px solid var(--line); color:var(--text-2); padding:0.4rem 0.6rem; border-radius:4px; font-size:0.85rem"
                >
                  <%= for w <- @workflows do %>
                    <option value={w.name} selected={@new_template == w.name}>{w.name}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label style="display:block; color:var(--muted); font-size:0.75rem; margin-bottom:0.25rem; text-transform:uppercase">Scope</label>
                <select
                  name="sector"
                  style="width:100%; background:var(--ground); border:1px solid var(--line); color:var(--text-2); padding:0.4rem 0.6rem; border-radius:4px; font-size:0.85rem"
                >
                  <option value="" selected={@new_sector == ""}>Global</option>
                  <%= for {name, id} <- @sectors do %>
                    <option value={id} selected={@new_sector == id}>Sector: {name}</option>
                  <% end %>
                </select>
              </div>
            </div>
            <button type="submit" class="btn btn-blue">Create</button>
            <span style="color:var(--muted); font-size:0.75rem; margin-left:0.75rem">
              Forked workflows live in
              <span style="font-family:monospace">
                <%= if @new_sector == "", do: "vault/Workflows/", else: "vault/Sectors/.../Workflows/" %>
              </span>
            </span>
          </form>
        </div>
      <% end %>

      <div class="panel">
        <div class="panel-title">Available workflows</div>

        <%= if @workflows == [] do %>
          <p style="color:var(--muted)">
            No workflows defined yet. The bundled <strong>standard</strong> workflow ships with
            the Factory and is used by default.
          </p>
        <% else %>
          <table style="width:100%; border-collapse:collapse">
            <thead>
              <tr style="text-align:left; color:var(--muted); font-size:0.75rem; text-transform:uppercase">
                <th style="padding:0.5rem 0.5rem; border-bottom:1px solid var(--line)">Name</th>
                <th style="padding:0.5rem 0.5rem; border-bottom:1px solid var(--line)">Phases</th>
                <th style="padding:0.5rem 0.5rem; border-bottom:1px solid var(--line)">Description</th>
                <th style="padding:0.5rem 0.5rem; border-bottom:1px solid var(--line)">Source</th>
              </tr>
            </thead>
            <tbody>
              <%= for w <- @workflows do %>
                <tr style="border-bottom:1px solid var(--line)">
                  <td style="padding:0.5rem 0.5rem">
                    <.link navigate={"/dashboard/workflows/" <> w.name} style="color:var(--accent)">{w.name}</.link>
                  </td>
                  <td style="padding:0.5rem 0.5rem">{length(w.phases)}</td>
                  <td style="padding:0.5rem 0.5rem; color:var(--muted)">{String.slice(w.description || "", 0, 80)}</td>
                  <td style="padding:0.5rem 0.5rem; color:var(--muted); font-size:0.75rem; font-family:monospace">
                    {short_path(w.source_path)}
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

  defp short_path(nil), do: "?"

  defp short_path(path) do
    case GiTF.gitf_dir() do
      {:ok, root} -> Path.relative_to(path, root)
      _ -> path
    end
  end

  defp list_sectors do
    GiTF.Archive.all(:sectors) |> Enum.map(fn s -> {s.name, s.id} end)
  rescue
    _ -> []
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp create_from_template(socket, name, template, sector_id) do
    with {:ok, source} <- GiTF.Workflow.resolve(template, sector_id),
         {:ok, target_path} <- compute_target_path(name, sector_id),
         :ok <- ensure_not_exists(target_path),
         forked = %{source | name: name, source_path: target_path},
         {:ok, _} <- GiTF.Workflow.write(forked, target_path) do
      {:noreply,
       socket
       |> assign(:workflows, GiTF.Workflow.list())
       |> assign(:show_new_form, false)
       |> assign(:new_name, "")
       |> push_navigate(to: "/dashboard/workflows/" <> name)}
    else
      {:error, :exists} ->
        {:noreply,
         push_toast(socket, "Workflow \"#{name}\" already exists at that scope", :error)}

      {:error, reason} ->
        {:noreply, push_toast(socket, "Create failed: #{inspect(reason)}", :error)}
    end
  end

  defp compute_target_path(name, sector_id) do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        base =
          if is_binary(sector_id) do
            Path.join([GiTF.Vault.Path.sector_dir(gitf_root, sector_id), "Workflows"])
          else
            Path.join(GiTF.Vault.Path.vault_root(gitf_root), "Workflows")
          end

        File.mkdir_p!(base)
        {:ok, Path.join(base, "#{name}.yaml")}

      err ->
        err
    end
  end

  defp ensure_not_exists(path) do
    if File.exists?(path), do: {:error, :exists}, else: :ok
  end
end
