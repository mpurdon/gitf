defmodule GiTF.Dashboard.MissionNewLive do
  @moduledoc "Mission creation form with GitHub issue selection."

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
     |> assign(:source, "manual")
     |> assign(:issues, [])
     |> assign(:issues_loading, false)
     |> assign(:issues_error, nil)
     |> assign(:selected_issue, nil)
     |> init_toasts()}
  end

  @impl true
  def handle_event("validate", %{"mission" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)

    # When sector changes, fetch issues if in issue mode
    socket =
      if params["sector"] != socket.assigns.form["sector"] and socket.assigns.source == "issue" do
        fetch_issues(socket, params["sector"])
      else
        socket
      end

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    quick = if mode == "quick", do: "true", else: "false"
    form = Map.put(socket.assigns.form, "quick", quick)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("set_source", %{"source" => source}, socket) do
    socket = assign(socket, :source, source)

    socket =
      if source == "issue" and socket.assigns.form["sector"] != "" do
        fetch_issues(socket, socket.assigns.form["sector"])
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("select_issue", %{"number" => number_str}, socket) do
    number = String.to_integer(number_str)
    issue = Enum.find(socket.assigns.issues, &(&1["number"] == number))

    if issue do
      title = issue["title"] || ""
      body = issue["body"] || ""
      labels = Enum.map_join(issue["labels"] || [], ", ", & &1["name"])
      url = issue["html_url"] || ""

      goal =
        [
          "Implement GitHub issue #{issue["number"]}: #{title}",
          if(body != "", do: body),
          if(labels != "", do: "Labels: #{labels}"),
          if(url != "", do: "Issue: #{url}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      name = "GH-#{number}: #{String.slice(title, 0, 60)}"

      form =
        socket.assigns.form
        |> Map.put("goal", goal)
        |> Map.put("name", name)

      {:noreply,
       socket
       |> assign(:form, form)
       |> assign(:selected_issue, number)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_issue", _, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue, nil)
     |> assign(:form, Map.merge(socket.assigns.form, %{"goal" => "", "name" => ""}))}
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

  # AppLayout subscribes to link:major — absorb all PubSub noise on this form page
  @impl true
  def handle_info({ref, {:ok, issues}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:issues, issues)
     |> assign(:issues_loading, false)
     |> assign(:issues_error, nil)}
  end

  def handle_info({ref, {:error, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:issues, [])
     |> assign(:issues_loading, false)
     |> assign(:issues_error, inspect(reason))}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp fetch_issues(socket, "") do
    assign(socket, issues: [], issues_error: nil, issues_loading: false)
  end

  defp fetch_issues(socket, sector_id) do
    sector = Enum.find(socket.assigns.sectors, &(&1.id == sector_id))

    if sector && Map.get(sector, :github_owner) && Map.get(sector, :github_repo) do
      # Fetch async to avoid blocking the LiveView
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        GiTF.GitHub.list_issues(sector)
      end)

      assign(socket, issues_loading: true, issues_error: nil, selected_issue: nil)
    else
      assign(socket, issues: [], issues_error: nil, issues_loading: false, selected_issue: nil)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, String.trim(value))

  defp has_github?(sectors) do
    Enum.any?(sectors, fn s ->
      Map.get(s, :github_owner) && Map.get(s, :github_repo)
    end)
  end

  defp issue_row_style(true), do: "display:flex; align-items:flex-start; gap:0.75rem; padding:0.6rem 0.75rem; cursor:pointer; border-bottom:1px solid #21262d; background:#1a2a3a"
  defp issue_row_style(false), do: "display:flex; align-items:flex-start; gap:0.75rem; padding:0.6rem 0.75rem; cursor:pointer; border-bottom:1px solid #21262d"

  defp issue_title_style(true), do: "font-size:0.85rem; color:#58a6ff; font-weight:600"
  defp issue_title_style(false), do: "font-size:0.85rem; color:#c9d1d9"

  defp label_style(color) do
    c = color || "6b7280"
    "font-size:0.7rem; padding:0 0.4rem; border-radius:10px; background:##{c}22; color:##{c}; border:1px solid ##{c}55"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="max-width:640px">
        <h1 class="page-title">New Mission</h1>

        <%= if has_github?(@sectors) do %>
          <div style="display:flex; gap:0; border-radius:6px; overflow:hidden; border:1px solid #30363d; margin-bottom:1rem">
            <div
              phx-click="set_source"
              phx-value-source="manual"
              style={"flex:1; text-align:center; cursor:pointer; padding:0.5rem 1rem; font-size:0.85rem; #{if @source == "manual", do: "background:#1c2128; color:#c9d1d9; border-bottom:2px solid #58a6ff", else: "background:#0d1117; color:#6b7280"}"}
            >
              Manual
            </div>
            <div
              phx-click="set_source"
              phx-value-source="issue"
              style={"flex:1; text-align:center; cursor:pointer; padding:0.5rem 1rem; font-size:0.85rem; border-left:1px solid #30363d; #{if @source == "issue", do: "background:#1c2128; color:#c9d1d9; border-bottom:2px solid #58a6ff", else: "background:#0d1117; color:#6b7280"}"}
            >
              GitHub Issue
            </div>
          </div>
        <% end %>

        <div class="panel">
          <form phx-submit="create" phx-change="validate">
            <div class="form-group">
              <label class="form-label">Sector</label>
              <select name="mission[sector]" class="form-select">
                <option value="">— Select sector —</option>
                <%= for sector <- @sectors do %>
                  <option value={sector.id} selected={@form["sector"] == sector.id}>
                    {sector.name}
                    <%= if Map.get(sector, :github_owner) do %>
                      ({sector.github_owner}/{sector.github_repo})
                    <% else %>
                      — {Map.get(sector, :path, "")}
                    <% end %>
                  </option>
                <% end %>
              </select>
            </div>

            <%= if @source == "issue" do %>
              <div class="form-group">
                <label class="form-label">Issue</label>
                <%= cond do %>
                  <% @form["sector"] == "" -> %>
                    <p style="color:#6b7280; font-size:0.85rem">Select a sector with GitHub config to browse issues.</p>

                  <% @issues_loading -> %>
                    <p style="color:#8b949e; font-size:0.85rem">Loading issues...</p>

                  <% @issues_error -> %>
                    <p style="color:#f85149; font-size:0.85rem">Failed to load issues: {@issues_error}</p>

                  <% @issues == [] -> %>
                    <p style="color:#6b7280; font-size:0.85rem">
                      No open issues found.
                      <%= unless has_github?(Enum.filter(@sectors, & &1.id == @form["sector"])) do %>
                        This sector has no GitHub config — add <code>github_owner</code> and <code>github_repo</code>.
                      <% end %>
                    </p>

                  <% true -> %>
                    <div style="max-height:300px; overflow-y:auto; border:1px solid #30363d; border-radius:6px">
                      <%= for issue <- @issues do %>
                        <% inum = issue["number"] %>
                        <div
                          phx-click="select_issue"
                          phx-value-number={inum}
                          style={issue_row_style(@selected_issue == inum)}
                        >
                          <span style="color:#3fb950; font-size:0.8rem; min-width:3rem; text-align:right">
                            #{inum}
                          </span>
                          <div style="flex:1; min-width:0">
                            <div style={issue_title_style(@selected_issue == inum)}>
                              {issue["title"]}
                            </div>
                            <%= if issue["labels"] != [] do %>
                              <div style="display:flex; gap:0.25rem; flex-wrap:wrap; margin-top:0.25rem">
                                <%= for label <- issue["labels"] || [] do %>
                                  <span style={label_style(label["color"])}>
                                    {label["name"]}
                                  </span>
                                <% end %>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                    <%= if @selected_issue do %>
                      <div style="margin-top:0.5rem; display:flex; align-items:center; gap:0.5rem">
                        <span style="color:#3fb950; font-size:0.85rem">Issue #{@selected_issue} selected</span>
                        <button type="button" phx-click="clear_issue" style="color:#6b7280; font-size:0.75rem; background:none; border:none; cursor:pointer; text-decoration:underline">clear</button>
                      </div>
                    <% end %>
                <% end %>
              </div>
            <% end %>

            <div class="form-group">
              <label class="form-label">Goal *</label>
              <textarea
                id="mission-goal-input"
                name="mission[goal]"
                class="form-textarea"
                placeholder={if @source == "issue", do: "Select an issue above or type a goal...", else: "Describe what you want to accomplish..."}
                style="min-height:120px"
                required
                phx-debounce="300"
              ><%= @form["goal"] %></textarea>
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
                id="mission-name-input"
                type="text"
                name="mission[name]"
                class="form-input"
                placeholder="Short name for this mission"
                value={@form["name"]}
                phx-debounce="300"
              />
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
