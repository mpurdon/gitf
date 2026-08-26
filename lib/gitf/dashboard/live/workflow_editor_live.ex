defmodule GiTF.Dashboard.WorkflowEditorLive do
  @moduledoc """
  Visual workflow editor.

  Phase cards in a vertical list, drag to reorder via Sortable.js
  (hooked through `Hooks.SortablePhases` in the dashboard layout). A
  side panel shows the selected phase's config as a form. Save serializes
  the in-memory workflow back to YAML in the vault.

  Working state is kept entirely in the LiveView socket — the on-disk
  YAML is only touched on save (so an operator can experiment with
  reorderings, validate, then commit or discard via the back button).
  """

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  alias GiTF.Workflow

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Workflow.resolve(name) do
      {:ok, workflow} ->
        {:ok,
         socket
         |> assign(:page_title, "Workflow: #{name}")
         |> assign(:current_path, "/workflows")
         |> assign(:workflow, workflow)
         |> assign(:selected_phase_id, nil)
         |> assign(:dirty?, false)
         |> assign(:validation_errors, [])
         |> init_toasts()}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:page_title, "Workflow not found")
         |> assign(:current_path, "/workflows")
         |> assign(:workflow, nil)
         |> assign(:load_error, reason)
         |> init_toasts()}
    end
  end

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("select_phase", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_phase_id, id)}
  end

  def handle_event("reorder_phases", %{"order" => order}, socket) when is_list(order) do
    workflow = socket.assigns.workflow
    by_id = Map.new(workflow.phases, fn p -> {p.id, p} end)

    reordered =
      order
      |> Enum.flat_map(fn id ->
        case Map.get(by_id, id) do
          nil -> []
          phase -> [phase]
        end
      end)

    new_workflow = %{workflow | phases: reordered}

    {:noreply,
     socket
     |> assign(:workflow, new_workflow)
     |> assign(:dirty?, true)
     |> assign(:validation_errors, validate(new_workflow))}
  end

  def handle_event("update_phase", params, socket) do
    id = params["phase_id"]
    workflow = socket.assigns.workflow

    new_phases =
      Enum.map(workflow.phases, fn p ->
        if p.id == id, do: apply_phase_edits(p, params), else: p
      end)

    new_workflow = %{workflow | phases: new_phases}

    {:noreply,
     socket
     |> assign(:workflow, new_workflow)
     |> assign(:dirty?, true)
     |> assign(:validation_errors, validate(new_workflow))}
  end

  def handle_event("add_phase", %{"position" => position}, socket) do
    workflow = socket.assigns.workflow
    pos = parse_position(position, length(workflow.phases))

    new_id = unique_phase_id(workflow.phases)
    next_target = phase_after(workflow.phases, pos)

    new_phase = %GiTF.Workflow.Phase{
      id: new_id,
      handler: GiTF.Phases.Default,
      next: next_target,
      max_retries: 0
    }

    new_phases = List.insert_at(workflow.phases, pos, new_phase)
    new_workflow = %{workflow | phases: new_phases}

    {:noreply,
     socket
     |> assign(:workflow, new_workflow)
     |> assign(:selected_phase_id, new_id)
     |> assign(:dirty?, true)
     |> assign(:validation_errors, validate(new_workflow))}
  end

  def handle_event("remove_phase", %{"id" => id}, socket) do
    workflow = socket.assigns.workflow
    new_phases = Enum.reject(workflow.phases, &(&1.id == id))

    # Patch any references to the removed phase. Targets pointing at the
    # removed id are rewritten to "end" so the workflow at least loads;
    # the operator can fix them up afterwards.
    new_phases =
      Enum.map(new_phases, fn p ->
        %{
          p
          | next: rewrite_target(p.next, id),
            on_pass: rewrite_target(p.on_pass, id),
            on_fail: rewrite_target(p.on_fail, id)
        }
      end)

    new_workflow = %{workflow | phases: new_phases}

    selected =
      if socket.assigns.selected_phase_id == id, do: nil, else: socket.assigns.selected_phase_id

    {:noreply,
     socket
     |> assign(:workflow, new_workflow)
     |> assign(:selected_phase_id, selected)
     |> assign(:dirty?, true)
     |> assign(:validation_errors, validate(new_workflow))}
  end

  def handle_event("save", _params, socket) do
    workflow = socket.assigns.workflow

    case validate(workflow) do
      [] ->
        case Workflow.write(workflow) do
          {:ok, path} ->
            {:noreply,
             socket
             |> assign(:dirty?, false)
             |> push_toast("Saved to #{Path.basename(path)}", :success)}

          {:error, reason} ->
            {:noreply, push_toast(socket, "Save failed: #{inspect(reason)}", :error)}
        end

      errors ->
        {:noreply,
         socket
         |> assign(:validation_errors, errors)
         |> push_toast("Validation failed — see errors above", :error)}
    end
  end

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(%{workflow: nil} = assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <h1 class="page-title">Workflow not found</h1>
      <p>{inspect(@load_error)}</p>
      <.link navigate="/dashboard/workflows" style="color:#58a6ff">← Back to workflows</.link>
    </.live_component>
    """
  end

  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <style>
        .phase-card { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:0.75rem 1rem; margin-bottom:0.5rem; cursor:pointer; transition:border-color 0.15s }
        .phase-card:hover { border-color:#58a6ff }
        .phase-card.selected { border-color:#58a6ff; background:#1c2128 }
        .phase-card-ghost { opacity:0.4 }
        .phase-card-chosen { border-color:#58a6ff !important }
        .drag-handle { cursor:grab; color:#6e7681; padding:0 0.5rem; user-select:none; font-size:1.1rem }
        .drag-handle:active { cursor:grabbing }
        .pill { display:inline-block; padding:0.1rem 0.45rem; border-radius:9999px; font-size:0.7rem; background:#21262d; color:#8b949e; margin-left:0.5rem }
        .pill-tier { background:#1f6feb33; color:#58a6ff }
        .pill-warn { background:#f8514933; color:#f85149 }
        .arrow { color:#6e7681; padding:0 0.5rem; font-size:0.9rem }
        .editor-grid { display:grid; grid-template-columns:1fr 1fr; gap:1.5rem }
        @media (max-width: 900px) { .editor-grid { grid-template-columns:1fr } }
        .field { margin-bottom:0.75rem }
        .field label { display:block; color:#8b949e; font-size:0.75rem; margin-bottom:0.25rem; text-transform:uppercase }
        .field input, .field select { width:100%; background:#0d1117; border:1px solid #30363d; color:#c9d1d9; padding:0.4rem 0.6rem; border-radius:4px; font-size:0.85rem }
        .field input:focus, .field select:focus { outline:none; border-color:#58a6ff }
      </style>

      <div style="display:flex; align-items:center; gap:1rem; margin-bottom:1rem">
        <.link navigate="/dashboard/workflows" style="color:#58a6ff; font-size:0.85rem">← Workflows</.link>
        <h1 class="page-title" style="margin:0">{@workflow.name}</h1>
        <%= if @dirty? do %>
          <span class="pill pill-warn">unsaved</span>
        <% end %>
      </div>

      <%= if @workflow.description do %>
        <p style="color:#8b949e; font-size:0.85rem; margin-bottom:1rem">{@workflow.description}</p>
      <% end %>

      <%= if @validation_errors != [] do %>
        <div style="background:#f8514922; border:1px solid #f85149; padding:0.75rem; margin-bottom:1rem; border-radius:6px">
          <strong style="color:#f85149">Validation errors:</strong>
          <ul style="margin:0.5rem 0 0 1.25rem; color:#c9d1d9; font-size:0.85rem">
            <%= for err <- @validation_errors do %>
              <li>{inspect(err)}</li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <div class="editor-grid">
        <!-- Left: drag-drop phase list -->
        <div class="panel">
          <div class="panel-title">Phases ({length(@workflow.phases)})</div>
          <p style="color:#8b949e; font-size:0.75rem; margin-bottom:0.75rem">
            Drag the <span class="drag-handle">≡</span> handle to reorder. Click a card to edit its config.
          </p>

          <button
            class="btn add-phase-btn"
            phx-click="add_phase"
            phx-value-position="0"
            style="display:block; width:100%; padding:0.4rem; margin-bottom:0.5rem; background:transparent; border:1px dashed #30363d; color:#6e7681; border-radius:6px; cursor:pointer; font-size:0.8rem"
          >
            + Add phase at top
          </button>

          <ul id="phase-list" phx-hook="SortablePhases" style="list-style:none; padding:0; margin:0">
            <%= for {phase, idx} <- Enum.with_index(@workflow.phases) do %>
              <li
                data-phase-id={phase.id}
                class={"phase-card " <> if(@selected_phase_id == phase.id, do: "selected", else: "")}
              >
                <div style="display:flex; align-items:center" phx-click="select_phase" phx-value-id={phase.id}>
                  <span class="drag-handle">≡</span>
                  <strong style="flex:1">{phase.id}</strong>
                  <%= if phase.model_tier do %>
                    <span class="pill pill-tier">{phase.model_tier}</span>
                  <% end %>
                  <%= if phase.gate do %>
                    <span class="pill">gate</span>
                  <% end %>
                  <button
                    phx-click="remove_phase"
                    phx-value-id={phase.id}
                    data-confirm={"Remove phase \"" <> phase.id <> "\"?"}
                    style="background:none; border:none; color:#6e7681; cursor:pointer; padding:0 0.25rem; margin-left:0.25rem; font-size:1rem"
                    title="Remove phase"
                  >
                    ✕
                  </button>
                </div>
                <div style="margin-top:0.4rem; padding-left:1.75rem; color:#8b949e; font-size:0.75rem">
                  <span class="arrow">→</span>{format_advance(phase)}
                  <%= if phase.timeout_minutes do %>
                    <span class="pill">{phase.timeout_minutes}m</span>
                  <% end %>
                  <%= if phase.inject_knowledge do %>
                    <span class="pill">📖 knowledge</span>
                  <% end %>
                  <%= if phase.inject_skills do %>
                    <span class="pill">🛠️ skills</span>
                  <% end %>
                </div>
              </li>
            <% end %>
          </ul>

          <button
            class="btn add-phase-btn"
            phx-click="add_phase"
            phx-value-position={length(@workflow.phases)}
            style="display:block; width:100%; padding:0.4rem; margin-top:0.5rem; background:transparent; border:1px dashed #30363d; color:#6e7681; border-radius:6px; cursor:pointer; font-size:0.8rem"
          >
            + Add phase at bottom
          </button>

          <div style="margin-top:1rem; display:flex; gap:0.5rem">
            <button class="btn btn-blue" phx-click="save" disabled={@validation_errors != []}>
              Save
            </button>
            <span style="color:#8b949e; font-size:0.75rem; align-self:center">
              <%= if @dirty?, do: "• Unsaved changes", else: "" %>
            </span>
          </div>
        </div>

        <!-- Right: phase config form -->
        <div class="panel">
          <%= if @selected_phase_id do %>
            <% phase = Enum.find(@workflow.phases, &(&1.id == @selected_phase_id)) %>
            <%= if phase do %>
              <div class="panel-title">Phase: {phase.id}</div>
              <.phase_form phase={phase} />
            <% end %>
          <% else %>
            <div class="panel-title">Phase configuration</div>
            <p style="color:#8b949e; font-size:0.85rem">
              Click a phase on the left to edit its config.
            </p>
          <% end %>
        </div>
      </div>
    </.live_component>
    """
  end

  # Per-phase form. Uses phx-change on the form so every keystroke
  # updates the in-memory workflow.
  defp phase_form(assigns) do
    ~H"""
    <form phx-change="update_phase">
      <input type="hidden" name="phase_id" value={@phase.id} />

      <div class="field">
        <label>handler</label>
        <input type="text" name="handler" value={handler_str(@phase.handler)} />
      </div>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem">
        <div class="field">
          <label>model_tier</label>
          <select name="model_tier">
            <option value="" selected={is_nil(@phase.model_tier)}>(default)</option>
            <option value="flash" selected={@phase.model_tier == :flash}>flash</option>
            <option value="general" selected={@phase.model_tier == :general}>general</option>
            <option value="opus" selected={@phase.model_tier == :opus}>opus</option>
          </select>
        </div>

        <div class="field">
          <label>timeout_minutes</label>
          <input type="number" name="timeout_minutes" value={@phase.timeout_minutes} min="1" />
        </div>
      </div>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem">
        <div class="field">
          <label>max_retries</label>
          <input type="number" name="max_retries" value={@phase.max_retries} min="0" />
        </div>

        <div class="field">
          <label>produces</label>
          <input type="text" name="produces" value={@phase.produces} />
        </div>
      </div>

      <div class="field">
        <label>reads (comma-separated)</label>
        <input type="text" name="reads" value={Enum.join(@phase.reads, ", ")} />
      </div>

      <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:0.75rem">
        <div class="field">
          <label>next</label>
          <%= if is_list(@phase.next) do %>
            <input type="text" name="next" value="(conditional — edit YAML)" disabled
              title={format_advance(@phase)} style="opacity:0.6" />
          <% else %>
            <input type="text" name="next" value={@phase.next} placeholder="phase id or 'end'" />
          <% end %>
        </div>

        <div class="field">
          <label>on_pass</label>
          <%= if is_list(@phase.on_pass) do %>
            <input type="text" name="on_pass" value="(conditional — edit YAML)" disabled style="opacity:0.6" />
          <% else %>
            <input type="text" name="on_pass" value={@phase.on_pass} placeholder="(verdict-driven)" />
          <% end %>
        </div>

        <div class="field">
          <label>on_fail</label>
          <%= if is_list(@phase.on_fail) do %>
            <input type="text" name="on_fail" value="(conditional — edit YAML)" disabled style="opacity:0.6" />
          <% else %>
            <input type="text" name="on_fail" value={@phase.on_fail} placeholder="(verdict-driven)" />
          <% end %>
        </div>
      </div>

      <div style="display:flex; gap:1.25rem; margin-top:0.5rem">
        <label style="display:flex; align-items:center; gap:0.4rem; color:#c9d1d9; font-size:0.8rem">
          <input type="checkbox" name="inject_knowledge" checked={@phase.inject_knowledge} value="true" />
          inject_knowledge
        </label>
        <label style="display:flex; align-items:center; gap:0.4rem; color:#c9d1d9; font-size:0.8rem">
          <input type="checkbox" name="inject_skills" checked={@phase.inject_skills} value="true" />
          inject_skills
        </label>
      </div>
    </form>
    """
  end

  # -- Helpers ---------------------------------------------------------------

  defp unique_phase_id(phases) do
    existing = MapSet.new(phases, & &1.id)

    Enum.find(Stream.iterate(1, &(&1 + 1)), &(not MapSet.member?(existing, "phase-#{&1}")))
    |> then(&"phase-#{&1}")
  end

  # When inserting a new phase at `position`, set its `next` to whatever
  # phase currently sits at that index — making the new phase chain in
  # sensibly. If we're inserting at the tail, point at "end".
  defp phase_after(phases, position) do
    case Enum.at(phases, position) do
      nil -> "end"
      phase -> phase.id
    end
  end

  defp rewrite_target(target, removed_id) when is_binary(target) and target == removed_id,
    do: "end"

  defp rewrite_target(target, _removed_id) when is_binary(target) or is_nil(target), do: target

  defp rewrite_target(transitions, removed_id) when is_list(transitions) do
    Enum.map(transitions, fn
      {:else, target} -> {:else, rewrite_target(target, removed_id)}
      {source, ast, target} -> {source, ast, rewrite_target(target, removed_id)}
    end)
  end

  defp apply_phase_edits(phase, params) do
    %{
      phase
      | handler: parse_handler(params["handler"]),
        model_tier: parse_tier(params["model_tier"]),
        timeout_minutes: parse_int(params["timeout_minutes"]),
        max_retries: parse_int(params["max_retries"]) || 0,
        produces: blank_to_nil(params["produces"]),
        reads: parse_csv(params["reads"]),
        # Conditional rules on next/on_pass/on_fail aren't editable via this
        # form yet — the text input is disabled when the value is a list — so
        # preserve them through phx-change cycles.
        next: if(is_list(phase.next), do: phase.next, else: blank_to_nil(params["next"])),
        on_pass:
          if(is_list(phase.on_pass), do: phase.on_pass, else: blank_to_nil(params["on_pass"])),
        on_fail:
          if(is_list(phase.on_fail), do: phase.on_fail, else: blank_to_nil(params["on_fail"])),
        inject_knowledge: params["inject_knowledge"] == "true",
        inject_skills: params["inject_skills"] == "true"
    }
  end

  # Default to "append" (end of list) on malformed input. Never raises:
  # a hostile websocket message can't kill the LV with String.to_integer.
  defp parse_position(p, _fallback) when is_integer(p), do: p

  defp parse_position(p, fallback) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} -> n
      _ -> fallback
    end
  end

  defp parse_position(_, fallback), do: fallback

  defp parse_handler(""), do: nil
  defp parse_handler(nil), do: nil

  # Operators can only pick handlers from the GiTF.Phases.* namespace.
  # Anything else (including non-existent atoms) silently becomes nil so
  # a hostile websocket message can't dispatch missions to e.g. :erlang
  # or File.
  defp parse_handler(name) when is_binary(name) do
    if String.starts_with?(name, "GiTF.Phases.") do
      try do
        String.to_existing_atom("Elixir." <> name)
      rescue
        ArgumentError -> nil
      end
    else
      nil
    end
  end

  defp parse_tier(""), do: nil
  defp parse_tier(nil), do: nil
  defp parse_tier("flash"), do: :flash
  defp parse_tier("general"), do: :general
  defp parse_tier("opus"), do: :opus
  defp parse_tier(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_csv(nil), do: []
  defp parse_csv(""), do: []

  defp parse_csv(s) when is_binary(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  # Conditional branches (next / on_pass / on_fail) are held as lists of
  # {expr | :else, target} tuples in the struct; the Schema validator (and
  # YAML on disk) want the map form. Round-trip it back for the
  # live-validation preview.
  defp branch_to_raw(transitions) when is_list(transitions) do
    Enum.map(transitions, fn
      {:else, target} -> %{"else" => target}
      {source, _ast, target} -> %{"when" => source, "then" => target}
    end)
  end

  defp branch_to_raw(other), do: other

  defp validate(workflow) do
    raw = %{
      "name" => workflow.name,
      "description" => workflow.description,
      "phases" =>
        Enum.map(workflow.phases, fn p ->
          %{
            "id" => p.id,
            "handler" => handler_str(p.handler),
            "model_tier" => if(p.model_tier, do: Atom.to_string(p.model_tier)),
            "timeout_minutes" => p.timeout_minutes,
            "max_retries" => p.max_retries,
            "inject_knowledge" => p.inject_knowledge,
            "inject_skills" => p.inject_skills,
            "reads" => p.reads,
            "produces" => p.produces,
            "next" => branch_to_raw(p.next),
            "on_pass" => branch_to_raw(p.on_pass),
            "on_fail" => branch_to_raw(p.on_fail)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end)
    }

    case GiTF.Workflow.Schema.validate(raw, workflow.source_path) do
      {:ok, _} -> []
      {:error, errors} -> errors
    end
  end

  defp handler_str(nil), do: nil

  defp handler_str(mod) when is_atom(mod),
    do: mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp format_advance(%{next: "end"}), do: "(end)"
  defp format_advance(%{next: next}) when is_binary(next), do: next

  defp format_advance(%{next: transitions}) when is_list(transitions) and transitions != [] do
    transitions
    |> Enum.map(fn
      {:else, t} -> "else→#{t}"
      {source, _ast, t} -> "#{source}→#{t}"
    end)
    |> Enum.join(" · ")
  end

  defp format_advance(%{on_pass: p, on_fail: f}) when is_binary(p) and is_binary(f),
    do: "pass→#{p} · fail→#{f}"

  defp format_advance(_), do: "?"
end
