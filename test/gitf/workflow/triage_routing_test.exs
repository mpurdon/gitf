defmodule GiTF.Workflow.TriageRoutingTest do
  @moduledoc """
  Guards the routing rules the workflow path actually uses.

  `workflow_dispatch_active?/1` needs only `workflow_dsl_enabled` (default
  true) and a non-empty `workflow_id`, so bundled templates advance through
  `advance_via_workflow/2` and their YAML `next:` rules — not through
  `Orchestrator.Decisions`. A routing fix applied only to the Elixir side is
  therefore invisible in production, which is exactly what happened to
  msn-8e0eae: `Decisions.next_phase_after_triage/2` learned not to send a
  design-less mission to review, `standard.yaml` did not, and the mission
  burned a thinking-tier review ghost on an empty design artifact before
  routing to design anyway.
  """

  use ExUnit.Case, async: true

  alias GiTF.Workflow

  @templates Path.wildcard(Path.join(:code.priv_dir(:gitf), "workflows/*.yaml"))

  defp triage_targets(workflow) do
    case Enum.find(workflow.phases, &(&1.id == "triage")) do
      nil ->
        []

      phase ->
        # Parsed rules are {expr_string, quoted_ast, target} for `when:`
        # clauses and {:else, target} for the fallthrough; a phase with a
        # single unconditional `next:` is just the target string.
        case phase.next do
          rules when is_list(rules) ->
            rules
            |> Enum.map(fn
              {_expr, _ast, target} -> target
              {:else, target} -> target
              target when is_binary(target) -> target
              _ -> nil
            end)
            |> Enum.reject(&is_nil/1)

          target when is_binary(target) ->
            [target]

          _ ->
            []
        end
    end
  end

  for path <- @templates do
    @path path

    test "#{Path.basename(path)}: triage never routes straight to review" do
      {:ok, workflow} = Workflow.load(@path)

      refute "review" in triage_targets(workflow),
             "#{Path.basename(@path)} routes triage -> review. Review reads the design " <>
               "and nothing else, so arriving from triage means design was skipped and the " <>
               "review ghost judges an empty artifact."
    end
  end

  test "standard still routes triage to research when nothing is skipped" do
    {:ok, workflow} = Workflow.load(Path.join(:code.priv_dir(:gitf), "workflows/standard.yaml"))

    assert "research" in triage_targets(workflow)
  end

  describe "standard.yaml triage rules, evaluated" do
    # The `next:` rules are the live router, so assert on what they resolve
    # to rather than on their text. Skipping research/requirements/design is
    # the shape triage emits for a small change — the shape that used to end
    # up at review with no design to read.
    @skipped %{
      "skip_flags" => %{
        "skip_research" => true,
        "skip_requirements" => true,
        "skip_design" => true
      }
    }

    defp route(mission, artifact) do
      {:ok, workflow} = Workflow.load(Path.join(:code.priv_dir(:gitf), "workflows/standard.yaml"))
      triage = Enum.find(workflow.phases, &(&1.id == "triage"))

      Enum.find_value(triage.next, fn
        {source, _ast, target} ->
          case GiTF.Workflow.Expr.eval(source, %{artifact: artifact, mission: mission}) do
            {:ok, true} -> target
            _ -> nil
          end

        {:else, target} ->
          target

        target when is_binary(target) ->
          target
      end)
    end

    test "a forced full pipeline overrides triage's skip flags" do
      mission = %{pipeline_mode: "full", pipeline_mode_forced: true}

      assert route(mission, @skipped) == "research"
    end

    test "forcing fast leaves the skip flags alone" do
      mission = %{pipeline_mode: "fast", pipeline_mode_forced: true}

      assert route(mission, @skipped) == "planning"
    end

    test "a mode that merely happens to be full does not override" do
      assert route(%{pipeline_mode: "full"}, @skipped) == "planning"
    end

    test "skipping design lands on planning, never review" do
      assert route(%{}, @skipped) == "planning"
    end
  end

  test "standard keeps a path to design and to planning from triage" do
    {:ok, workflow} = Workflow.load(Path.join(:code.priv_dir(:gitf), "workflows/standard.yaml"))
    targets = triage_targets(workflow)

    assert "design" in targets

    assert "planning" in targets,
           "dropping the review rule must fall through to planning, not skip to implementation"
  end
end
