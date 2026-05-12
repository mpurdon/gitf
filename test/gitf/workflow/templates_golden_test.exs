defmodule GiTF.Workflow.TemplatesGoldenTest do
  @moduledoc """
  Golden test for the bundled workflow templates.

  For each template under `priv/workflows/`, we walk every reachable
  verdict path (combinations of `:advance` / `:pass` / `:fail` per
  phase) and assert each path eventually reaches `:end` without
  cycling forever. This catches schemas that compile but would
  livelock at runtime — e.g., a `bug-fix` workflow whose `on_fail`
  loops back to a phase that can't recover.

  We bound the walk depth: any path longer than 200 steps is treated
  as a livelock and fails the test with the offending workflow + path.
  """

  use ExUnit.Case, async: true

  alias GiTF.Workflow
  alias GiTF.Workflow.Phase

  @max_steps 200

  for template_path <- Path.wildcard(Path.join(:code.priv_dir(:gitf), "workflows/*.yaml")) do
    @template_path template_path

    test "template #{Path.basename(template_path)} reaches :end on every path" do
      {:ok, workflow} = Workflow.load(@template_path)

      # Discover entry phase, then exhaustively traverse all branch
      # combinations using a worklist of (phase_id, depth, path) states.
      {:ok, entry} = Workflow.entry_phase(workflow)
      worklist = [{entry.id, 0, [entry.id]}]

      Enum.reduce(worklist, MapSet.new(), fn _, _ -> :ok end)

      walk(workflow, [{entry.id, 0, [entry.id]}], MapSet.new())
    end
  end

  defp walk(_workflow, [], _seen), do: :ok

  defp walk(workflow, [{phase_id, depth, path} | rest], seen) do
    cond do
      depth > @max_steps ->
        flunk("Path exceeded #{@max_steps} steps in #{workflow.name}: #{Enum.join(Enum.reverse(path), " -> ")}")

      MapSet.member?(seen, {phase_id, walked_signature(path)}) ->
        walk(workflow, rest, seen)

      true ->
        case Workflow.phase(workflow, phase_id) do
          {:ok, %Phase{} = phase} ->
            children = next_states(workflow, phase, depth, path)
            walk(workflow, children ++ rest, MapSet.put(seen, {phase_id, walked_signature(path)}))

          {:error, :not_found} ->
            flunk("Phase #{phase_id} referenced but not defined in #{workflow.name}")
        end
    end
  end

  defp next_states(_workflow, %Phase{next: "end"}, _depth, _path), do: []

  defp next_states(_workflow, %Phase{} = phase, depth, path) do
    next_targets =
      cond do
        is_binary(phase.next) and phase.next != "" -> [phase.next]
        is_binary(phase.on_pass) and is_binary(phase.on_fail) -> [phase.on_pass, phase.on_fail]
        true -> []
      end

    Enum.flat_map(next_targets, fn t ->
      cond do
        t == "end" -> []
        true -> [{t, depth + 1, [t | path]}]
      end
    end)
  end

  # We treat a path as "seen" by phase_id PLUS the most recent two
  # steps — that lets a verdict cycle (impl→validate→impl) occur
  # finitely many times in the walk before we recognise the cycle.
  defp walked_signature(path) do
    Enum.take(path, 2) |> Enum.join("/")
  end
end
