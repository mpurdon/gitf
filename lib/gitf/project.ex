defmodule GiTF.Project do
  @moduledoc """
  Context module for projects — multi-mission initiatives driven by Aramaki.

  A project is a high-level goal (captured as a `brief`) decomposed into a
  `roadmap`: a dependency DAG of items, each of which becomes a mission once
  every item it `depends_on` has completed. Aramaki advances active projects
  on its admission tick (see `GiTF.Aramaki.advance_projects/0`), so the same
  capacity and budget gates that protect issue-sourced work protect project
  work.

  Lifecycle: `draft` (being planned) → `active` (Aramaki is running it) →
  `completed` / `failed`. A mission failure pauses the project (`paused`)
  rather than cascading — the operator resumes or abandons it.

  Roadmap items carry `status`: `pending` → `active` (mission created) →
  `completed` / `failed`. An item is *ready* when it is pending and all of
  its dependencies have completed.
  """

  require Logger

  alias GiTF.Archive

  @statuses ~w(draft active paused completed failed)
  @item_statuses ~w(pending active completed failed)
  @sources ~w(cli_chat studio api github_issue)

  @doc "Project statuses considered in flight."
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: ~w(active paused)

  # -- CRUD --------------------------------------------------------------------

  @doc """
  Creates a project in `draft` status.

  Required attrs: `name`, `roadmap` (non-empty list of items with `title` and
  `goal`; `depends_on` lists other items' ids). Optional: `brief`, `sector_id`,
  `source`, `aramaki_priority`.

  Item ids are generated (`"item-1"`, ...) when omitted. The roadmap is
  validated as a DAG: unknown dependency ids and cycles are rejected.
  """
  @spec create(map()) :: {:ok, map()} | {:error, term()}
  def create(attrs) do
    name = field(attrs, :name)
    source = field(attrs, :source) || "api"

    with :ok <- require_fields(name: name),
         :ok <- validate_source(source),
         {:ok, roadmap} <- normalize_roadmap(field(attrs, :roadmap)) do
      record = %{
        name: name,
        status: "draft",
        sector_id: field(attrs, :sector_id),
        source: source,
        brief: normalize_brief(field(attrs, :brief)),
        roadmap: roadmap,
        artifacts: field(attrs, :artifacts) || %{},
        aramaki_priority: field(attrs, :aramaki_priority) || 2,
        paused_reason: nil
      }

      {:ok, project} = Archive.insert(:projects, record)

      GiTF.EventStore.record(:project_created, project.id, %{
        name: name,
        source: source,
        items: length(roadmap)
      })

      {:ok, project}
    end
  end

  @doc "Gets a project by id. Returns the record or nil."
  @spec get(String.t()) :: map() | nil
  def get(id), do: Archive.get(:projects, id)

  @doc "All projects."
  @spec list() :: [map()]
  def list, do: Archive.all(:projects)

  @doc "Projects in the given status."
  @spec by_status(String.t()) :: [map()]
  def by_status(status) when status in @statuses do
    Archive.filter(:projects, &(&1.status == status))
  end

  # -- Lifecycle ----------------------------------------------------------------

  @doc """
  Activates a draft project so Aramaki starts advancing it. Requires a
  `sector_id` — a project can't run without somewhere to run.
  """
  @spec activate(String.t()) :: {:ok, map()} | {:error, term()}
  def activate(id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %{status: "draft", sector_id: sector_id} when is_binary(sector_id) ->
        result = Archive.update(:projects, id, &Map.put(&1, :status, "active"))
        GiTF.EventStore.record(:project_activated, id, %{})
        GiTF.Aramaki.tick()
        result

      %{status: "draft"} ->
        {:error, :no_sector}

      %{status: other} ->
        {:error, {:invalid_status, other}}
    end
  end

  @doc """
  Assigns a sector to a draft project (planning may finish before the target
  repo exists — greenfield flows create the sector at approval time).
  """
  @spec assign_sector(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def assign_sector(id, sector_id) do
    with {:ok, _sector} <- GiTF.Sector.get(sector_id) do
      transition(id, ["draft"], "draft", &Map.put(&1, :sector_id, sector_id))
    end
  end

  @doc """
  Replaces a draft project's roadmap (same validation as `create/1`). Once a
  project is active its roadmap items are owned by Aramaki — pause first.
  """
  @spec update_roadmap(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def update_roadmap(id, items) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %{status: "draft"} ->
        with {:ok, roadmap} <- normalize_roadmap(items) do
          Archive.update(:projects, id, &Map.put(&1, :roadmap, roadmap))
        end

      %{status: other} ->
        {:error, {:invalid_status, other}}
    end
  end

  @doc "Pauses an active project (Aramaki stops creating its missions)."
  @spec pause(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pause(id, reason \\ nil) do
    transition(id, ["active"], "paused", fn p -> Map.put(p, :paused_reason, reason) end)
  end

  @doc "Resumes a paused project."
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(id) do
    with {:ok, project} <-
           transition(id, ["paused"], "active", &Map.put(&1, :paused_reason, nil)) do
      GiTF.Aramaki.tick()
      {:ok, project}
    end
  end

  # -- DAG advancement -----------------------------------------------------------

  @doc """
  Roadmap items ready to become missions: pending, no mission yet, and every
  dependency completed.
  """
  @spec ready_items(map()) :: [map()]
  def ready_items(%{roadmap: roadmap}) do
    completed =
      roadmap
      |> Enum.filter(&(&1.status == "completed"))
      |> MapSet.new(& &1.id)

    Enum.filter(roadmap, fn item ->
      item.status == "pending" and is_nil(item.mission_id) and
        Enum.all?(item.depends_on, &MapSet.member?(completed, &1))
    end)
  end

  @doc """
  Records that a mission was created for a roadmap item (item goes `active`).
  """
  @spec attach_mission(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def attach_mission(project_id, item_id, mission_id) do
    update_item(project_id, item_id, fn item ->
      %{item | status: "active", mission_id: mission_id}
    end)
  end

  @doc """
  Handles a project mission reaching a terminal state. Marks the roadmap item,
  completes the project when all items are done, and pauses it on failure.

  Called (best-effort) from `GiTF.Missions.notify_aramaki_terminal/2`.
  """
  @spec on_mission_terminal(map(), :completed | {:failed, String.t() | nil}) :: :ok
  def on_mission_terminal(mission, outcome) do
    with %{project_id: project_id, item_id: item_id} <- source_project(mission),
         %{} = project <- get(project_id) do
      case outcome do
        :completed ->
          {:ok, updated} =
            update_item(project_id, item_id, &Map.put(&1, :status, "completed"))

          if Enum.all?(updated.roadmap, &(&1.status == "completed")) do
            {:ok, _} = Archive.update(:projects, project_id, &Map.put(&1, :status, "completed"))
            GiTF.EventStore.record(:project_completed, project_id, %{name: project.name})
            Logger.info("Project #{project_id} (#{project.name}) completed")
          else
            # Dependents may have become ready — don't wait for the next tick.
            GiTF.Aramaki.tick()
          end

        {:failed, reason} ->
          {:ok, _} = update_item(project_id, item_id, &Map.put(&1, :status, "failed"))
          {:ok, _} = pause(project_id, "item #{item_id} failed: #{reason || "unknown"}")

          GiTF.EventStore.record(:project_paused, project_id, %{
            item_id: item_id,
            reason: reason
          })

          Logger.warning(
            "Project #{project_id} paused: roadmap item #{item_id} failed (#{reason || "unknown"})"
          )
      end

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  The goal text for a roadmap item's mission: the item goal plus a context
  section summarizing what each completed dependency's mission actually
  produced (outcome, branch, plan excerpt) — so later missions build on real
  state, not the planning-time guess.
  """
  @spec mission_goal(map(), map()) :: String.t()
  def mission_goal(project, item) do
    context =
      item.depends_on
      |> Enum.map(fn dep_id -> Enum.find(project.roadmap, &(&1.id == dep_id)) end)
      |> Enum.filter(&(&1 && &1.status == "completed" && &1.mission_id))
      |> Enum.map(&dependency_context/1)
      |> Enum.reject(&is_nil/1)

    base = "#{item.title}\n\n#{item.goal}"

    case context do
      [] ->
        base

      lines ->
        base <>
          "\n\n## Context from completed prerequisite missions\n\n" <> Enum.join(lines, "\n")
    end
  end

  @doc """
  Heals roadmap items whose mission reached a terminal state without the
  item being updated (missed notification: daemon restart, crash between
  completion and notify, or pre-fix builds). Called from Aramaki's tick
  before readiness is computed. Returns `:ok`.
  """
  @spec reconcile(map()) :: :ok
  def reconcile(project) do
    project.roadmap
    |> Enum.filter(&(&1.status == "active" and is_binary(&1.mission_id)))
    |> Enum.each(fn item ->
      case Archive.get(:missions, item.mission_id) do
        %{status: "completed"} = mission ->
          Logger.info("Project #{project.id}: reconciling item #{item.id} (mission completed)")
          on_mission_terminal(mission, :completed)

        %{status: status} = mission when status in ["failed", "killed"] ->
          Logger.info("Project #{project.id}: reconciling item #{item.id} (mission #{status})")
          on_mission_terminal(mission, {:failed, Map.get(mission, :failure_reason) || status})

        _ ->
          :ok
      end
    end)
  end

  # -- Internals -----------------------------------------------------------------

  defp dependency_context(item) do
    case Archive.get(:missions, item.mission_id) do
      nil ->
        nil

      mission ->
        branches =
          Archive.filter(:shells, &(&1[:mission_id] == item.mission_id))
          |> Enum.map(& &1[:branch])
          |> Enum.filter(&is_binary/1)

        branch_note =
          case branches do
            [] -> ""
            bs -> " Work is on branch(es): #{Enum.join(bs, ", ")}."
          end

        plan_note =
          case Map.get(mission, :implementation_plan) do
            plan when is_binary(plan) and plan != "" ->
              " Plan summary: #{String.slice(plan, 0, 500)}"

            _ ->
              ""
          end

        "- \"#{item.title}\" (mission #{mission.id}): #{mission.status}.#{branch_note}#{plan_note}"
    end
  end

  defp source_project(mission) do
    case Map.get(mission, :source_project) do
      %{project_id: _, item_id: _} = sp -> sp
      %{"project_id" => pid, "item_id" => iid} -> %{project_id: pid, item_id: iid}
      _ -> nil
    end
  end

  defp update_item(project_id, item_id, fun) do
    case get(project_id) do
      nil ->
        {:error, :not_found}

      %{roadmap: roadmap} ->
        if Enum.any?(roadmap, &(&1.id == item_id)) do
          Archive.update(:projects, project_id, fn p ->
            Map.update!(p, :roadmap, fn items ->
              Enum.map(items, fn
                %{id: ^item_id} = item -> fun.(item)
                item -> item
              end)
            end)
          end)
        else
          {:error, :item_not_found}
        end
    end
  end

  defp transition(id, from_statuses, to_status, fun) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %{status: status} = _project ->
        if status in from_statuses do
          Archive.update(:projects, id, fn p -> p |> Map.put(:status, to_status) |> fun.() end)
        else
          {:error, {:invalid_status, status}}
        end
    end
  end

  # -- Validation ----------------------------------------------------------------

  defp normalize_brief(nil),
    do: %{vision: nil, constraints: [], decisions: [], open_questions: [], precedents: []}

  defp normalize_brief(brief) when is_map(brief) do
    %{
      vision: field(brief, :vision),
      constraints: field(brief, :constraints) || [],
      decisions: field(brief, :decisions) || [],
      open_questions: field(brief, :open_questions) || [],
      precedents: field(brief, :precedents) || []
    }
  end

  defp normalize_roadmap(items) when is_list(items) and items != [] do
    items =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, idx} ->
        %{
          id: field(item, :id) || "item-#{idx}",
          title: field(item, :title),
          goal: field(item, :goal),
          depends_on: field(item, :depends_on) || [],
          status: "pending",
          mission_id: nil,
          workflow_id: field(item, :workflow_id),
          artifacts: field(item, :artifacts) || %{}
        }
      end)

    ids = MapSet.new(items, & &1.id)

    cond do
      MapSet.size(ids) != length(items) ->
        {:error, :duplicate_item_ids}

      Enum.any?(items, &(is_nil(&1.title) or is_nil(&1.goal))) ->
        {:error, {:missing_fields, [:title, :goal]}}

      (unknown = unknown_deps(items, ids)) != [] ->
        {:error, {:unknown_dependencies, unknown}}

      cyclic?(items) ->
        {:error, :dependency_cycle}

      true ->
        {:ok, items}
    end
  end

  defp normalize_roadmap(_), do: {:error, {:missing_fields, [:roadmap]}}

  defp unknown_deps(items, ids) do
    items
    |> Enum.flat_map(& &1.depends_on)
    |> Enum.reject(&MapSet.member?(ids, &1))
    |> Enum.uniq()
  end

  # Kahn's algorithm: if we can't peel every item, there's a cycle.
  defp cyclic?(items) do
    peel(items, MapSet.new()) != length(items)
  end

  defp peel(items, done) do
    {ready, blocked} =
      Enum.split_with(items, fn item ->
        Enum.all?(item.depends_on, &MapSet.member?(done, &1))
      end)

    case ready do
      [] -> MapSet.size(done)
      _ -> peel(blocked, Enum.into(ready, done, & &1.id))
    end
  end

  defp validate_source(source) when source in @sources, do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  defp require_fields(pairs) do
    case for {k, v} <- pairs, is_nil(v) or v == "", do: k do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  defp field(map, key) when is_atom(key), do: map[key] || map[Atom.to_string(key)]

  @doc false
  def item_statuses, do: @item_statuses
end
