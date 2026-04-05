defmodule GiTF.Major.FastPath do
  @moduledoc """
  Fast path for missions that don't need the full 7-phase pipeline.

  Bug fixes, single features, doc updates, and focused tasks skip
  research → requirements → design → review → planning and go straight
  to implementation with a single op and ghost. Verification still runs
  (Tachikoma reviews the work and SyncQueue merges it).

  A mission is auto-eligible if it has a short, focused goal without
  multi-system complexity indicators. It can also be forced onto the
  fast path with `force: true` (via `gitf run` or `--quick` flag).
  """

  require Logger

  # Keywords that signal multi-system complexity requiring the full pipeline
  @complex_keywords ~w(migration infrastructure architect redesign
    credential secret multi-service distributed)

  @max_goal_length 1000

  @doc """
  Returns true if a mission is simple enough for the fast path.

  Checks:
  - Goal is under 1000 chars (focused, not a spec)
  - No multi-system complexity keywords
  - No excessive file references (more than 5 file paths)
  - No existing artifacts (hasn't started the pipeline)

  Can be bypassed with `force: true` in opts.
  """
  @spec eligible?(map(), keyword()) :: boolean()
  def eligible?(mission, opts \\ []) do
    if Keyword.get(opts, :force, false) do
      true
    else
      goal = Map.get(mission, :goal, "")
      goal_lower = String.downcase(goal)
      artifacts = Map.get(mission, :artifacts, %{})

      short_goal?(goal) and
        no_complex_keywords?(goal_lower) and
        no_multi_file_refs?(goal) and
        no_existing_artifacts?(artifacts)
    end
  end

  @doc """
  Executes the fast path: transitions directly to implementation, creates
  a single op, and spawns a single ghost. Verification is NOT skipped —
  the op goes through the standard Tachikoma review and merge pipeline.

  Returns `{:ok, "implementation"}` or `{:error, reason}`.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         {:ok, _} <-
           GiTF.Missions.transition_phase(mission_id, "implementation", "Fast path: focused task") do
      # Create a single implementation op (verification enabled)
      job_attrs = %{
        title: mission.goal,
        description: mission.goal,
        mission_id: mission_id,
        sector_id: mission.sector_id,
        phase_job: false,
        skip_verification: false
      }

      case GiTF.Ops.create(job_attrs) do
        {:ok, op} ->
          Logger.info("Fast path: created op #{op.id} for mission #{mission_id}")

          # Spawn a ghost for the op
          case GiTF.gitf_dir() do
            {:ok, gitf_root} ->
              case GiTF.Ghosts.spawn_detached(op.id, mission.sector_id, gitf_root) do
                {:ok, ghost} ->
                  Logger.info("Fast path: spawned ghost #{ghost.id} for mission #{mission_id}")
                  {:ok, "implementation"}

                {:error, reason} ->
                  Logger.error(
                    "Fast path: ghost spawn failed for mission #{mission_id}: #{inspect(reason)}"
                  )

                  {:error, {:spawn_failed, reason}}
              end

            {:error, _} ->
              Logger.warning(
                "Fast path: no gitf root, op #{op.id} will be picked up by scheduler"
              )

              {:ok, "implementation"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- Private ---------------------------------------------------------------

  defp short_goal?(goal), do: String.length(goal) < @max_goal_length

  defp no_complex_keywords?(goal_lower) do
    not Enum.any?(@complex_keywords, &String.contains?(goal_lower, &1))
  end

  defp no_multi_file_refs?(goal) do
    file_refs =
      goal
      |> String.split(~r/\s+/)
      |> Enum.count(fn word ->
        String.contains?(word, "/") or Regex.match?(~r/\.\w{1,4}$/, word)
      end)

    file_refs <= 5
  end

  defp no_existing_artifacts?(artifacts) when map_size(artifacts) == 0, do: true
  defp no_existing_artifacts?(_), do: false
end
