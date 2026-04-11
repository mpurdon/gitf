defmodule GiTF.Dashboard.MissionNewLive do
  @moduledoc "Mission creation form."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  @impl true
  def mount(_params, _session, socket) do
    sectors =
      try do
        GiTF.Sector.list()
      rescue
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "New Mission")
     |> assign(:current_path, "/dashboard/missions")
     |> assign(:sectors, sectors)
     |> assign(:form, %{"goal" => "", "name" => "", "sector" => "", "quick" => "false"})
     |> init_toasts()}
  end

  @impl true
  def handle_event("validate", %{"mission" => params}, socket) do
    {:noreply, assign(socket, :form, Map.merge(socket.assigns.form, params))}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    quick = if mode == "quick", do: "true", else: "false"
    form = Map.put(socket.assigns.form, "quick", quick)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create", %{"mission" => params}, socket) do
    attrs =
      %{goal: String.trim(params["goal"])}
      |> maybe_put(:name, params["name"])
      |> maybe_put(:sector_id, params["sector"])

    quick = params["quick"] == "true"
    review = params["review_plan"] == "true"
    attrs = if review, do: Map.put(attrs, :review_plan, true), else: attrs

    case GiTF.Missions.create(attrs) do
      {:ok, mission} ->
        if quick do
          case GiTF.Major.Orchestrator.start_quest(mission.id, force_fast_path: true) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Quick task started — ghost is working.")
               |> push_navigate(to: "/dashboard/missions/#{mission.id}")}

            {:error, reason} ->
              {:noreply,
               socket
               |> put_flash(:error, "Created mission but failed to start: #{inspect(reason)}")
               |> push_navigate(to: "/dashboard/missions/#{mission.id}")}
          end
        else
          # Full pipeline: auto-start, will pause at planning if review requested
          case GiTF.Major.Orchestrator.start_quest(mission.id, force_full_pipeline: true) do
            {:ok, _} ->
              flash =
                if review,
                  do: "Mission started — will pause at planning for your review.",
                  else: "Mission started — running full pipeline."

              {:noreply,
               socket
               |> put_flash(:info, flash)
               |> push_navigate(to: "/dashboard/missions/#{mission.id}")}

            {:error, reason} ->
              {:noreply,
               socket
               |> put_flash(:error, "Created but failed to start: #{inspect(reason)}")
               |> push_navigate(to: "/dashboard/missions/#{mission.id}")}
          end
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create mission: #{inspect(reason)}")}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, String.trim(value))

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="max-width:640px">
        <h1 class="page-title">New Mission</h1>

        <div class="panel">
          <form phx-submit="create" phx-change="validate">
            <div class="form-group">
              <label class="form-label">Goal *</label>
              <textarea
                name="mission[goal]"
                class="form-textarea"
                placeholder="Describe what you want to accomplish..."
                style="min-height:120px"
                required
              >{@form["goal"]}</textarea>
            </div>

            <!-- Mode toggle buttons -->
            <div class="form-group">
              <% is_quick = @form["quick"] == "true" %>
              <input type="hidden" name="mission[quick]" value={if is_quick, do: "true", else: "false"} />
              <div style="display:flex; gap:0; border-radius:6px; overflow:hidden; border:1px solid #30363d">
                <div
                  phx-click="set_mode"
                  phx-value-mode="quick"
                  style={"flex:1; display:flex; align-items:center; justify-content:center; gap:0.5rem; cursor:pointer; padding:0.6rem 1rem; font-size:0.85rem; #{if is_quick, do: "background:#1a3a2a; color:#3fb950", else: "background:#1c2128; color:#6b7280"}"}
                >
                  <strong>Quick Run</strong>
                  <span style="font-size:0.75rem; opacity:0.7">single ghost, fast</span>
                </div>
                <div
                  phx-click="set_mode"
                  phx-value-mode="full"
                  style={"flex:1; display:flex; align-items:center; justify-content:center; gap:0.5rem; cursor:pointer; padding:0.6rem 1rem; font-size:0.85rem; border-left:1px solid #30363d; #{if !is_quick, do: "background:#1a2a3a; color:#58a6ff", else: "background:#1c2128; color:#6b7280"}"}
                >
                  <strong>Full Pipeline</strong>
                  <span style="font-size:0.75rem; opacity:0.7">research, plan, verify</span>
                </div>
              </div>
              <%= unless is_quick do %>
                <label style="display:flex; align-items:center; gap:0.5rem; cursor:pointer; color:#c9d1d9; font-size:0.85rem; margin-top:0.5rem; padding:0.4rem 0.75rem; background:#1c2128; border-radius:4px; border:1px solid #30363d">
                  <input type="checkbox" name="mission[review_plan]" value="true" checked={@form["review_plan"] == "true"} style="accent-color:#a855f7" />
                  <span>
                    <strong style="color:#a855f7">Review plan</strong>
                    <span style="color:#8b949e"> — pause at planning for manual review</span>
                  </span>
                </label>
              <% end %>
            </div>

            <div class="form-group">
              <label class="form-label">Name (optional)</label>
              <input
                type="text"
                name="mission[name]"
                class="form-input"
                placeholder="Short name for this mission"
                value={@form["name"]}
              />
            </div>

            <div class="form-group">
              <label class="form-label">Sector</label>
              <select name="mission[sector]" class="form-select">
                <option value="">— Default sector —</option>
                <%= for sector <- @sectors do %>
                  <option value={sector.id} selected={@form["sector"] == sector.id}>
                    {sector.name} — {Map.get(sector, :path, "")}
                  </option>
                <% end %>
              </select>
            </div>

            <div class="action-bar">
              <a href="/dashboard/missions" class="btn btn-grey">Cancel</a>
              <button type="submit" class="btn btn-green" disabled={String.trim(@form["goal"] || "") == ""}>
                {if @form["quick"] == "true", do: "Run Task", else: "Create Mission"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </.live_component>
    """
  end
end
