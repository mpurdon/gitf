defmodule GiTF.Workflow.PhaseCallbacksTest do
  @moduledoc """
  Foundation tests for the Phase-behaviour callbacks that the standard-
  workflow migration relies on: `verdict/2` preference over `verdict/1`,
  the `:terminal_complete` / `:terminal_fail` verdict short-circuits, and
  the `terminal/2` callback used to override the workflow's default
  completion semantics.
  """
  use GiTF.StoreCase

  alias GiTF.Workflow
  alias GiTF.Workflow.{Advancer, Phase}

  defmodule UsesArity2 do
    @behaviour GiTF.Phase

    def start(_m, _pc, _ctx), do: {:ok, :spawned}

    # /2 form sees the mission — return :pass when mission.flag is set.
    def verdict(mission, _artifact) do
      case Map.get(mission, :flag) do
        true -> :pass
        :terminal -> :terminal_fail
        :done -> :terminal_complete
        _ -> :advance
      end
    end

    # /1 form would say :advance always; the /2 should win.
    def verdict(_artifact), do: :advance
  end

  defmodule RecordsTerminal do
    @behaviour GiTF.Phase

    def start(_m, _pc, _ctx), do: {:ok, :spawned}

    # Stash kind on the mission so the test can observe what fired.
    def terminal(mission, kind) do
      GiTF.Archive.update(:missions, mission.id, fn m -> Map.put(m, :terminal_kind, kind) end)
      :ok
    end
  end

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(%{name: "p", goal: "x", status: "active", sector_id: "fe", artifacts: %{}}, attrs)
      )

    m
  end

  describe "Advancer prefers verdict/2 over verdict/1" do
    test "/2 wins when both are exported" do
      w = %Workflow{
        name: "t",
        phases: [
          %Phase{id: "p", handler: UsesArity2, on_pass: "done", on_fail: "p", max_retries: 0},
          %Phase{id: "done", next: "end"}
        ]
      }

      m =
        insert_mission!(%{
          current_phase: "p",
          flag: true,
          artifacts: %{"p" => %{"any" => "thing"}}
        })

      assert {:dispatch, "done"} = Advancer.decide(m, w)
    end
  end

  describe ":terminal_complete / :terminal_fail short-circuit max_retries" do
    test ":terminal_complete maps to :complete regardless of retry budget" do
      w = %Workflow{
        name: "t",
        phases: [
          %Phase{id: "p", handler: UsesArity2, on_pass: "p", on_fail: "p", max_retries: 99},
          %Phase{id: "x", next: "end"}
        ]
      }

      m =
        insert_mission!(%{
          current_phase: "p",
          flag: :done,
          artifacts: %{"p" => %{"a" => "b"}}
        })

      assert :complete = Advancer.decide(m, w)
    end

    test ":terminal_fail maps to :retries_exhausted regardless of retry budget" do
      w = %Workflow{
        name: "t",
        phases: [
          %Phase{id: "p", handler: UsesArity2, on_pass: "p", on_fail: "p", max_retries: 99},
          %Phase{id: "x", next: "end"}
        ]
      }

      m =
        insert_mission!(%{
          current_phase: "p",
          flag: :terminal,
          artifacts: %{"p" => %{"a" => "b"}}
        })

      assert {:retries_exhausted, "p"} = Advancer.decide(m, w)
    end
  end

  describe "invoke_terminal/3" do
    test "calls handler.terminal/2 when exported" do
      w = %Workflow{
        name: "t",
        phases: [%Phase{id: "p", handler: RecordsTerminal, next: "end"}]
      }

      m = insert_mission!(%{current_phase: "p"})

      assert {:ok, :handled} = Advancer.invoke_terminal(m, w, :complete)
      assert GiTF.Archive.get(:missions, m.id).terminal_kind == :complete

      assert {:ok, :handled} = Advancer.invoke_terminal(m, w, :retries_exhausted)
      assert GiTF.Archive.get(:missions, m.id).terminal_kind == :retries_exhausted
    end

    test "returns :default when no handler.terminal/2 is exported" do
      w = %Workflow{name: "t", phases: [%Phase{id: "p", handler: UsesArity2, next: "end"}]}
      m = insert_mission!(%{current_phase: "p"})
      assert :default = Advancer.invoke_terminal(m, w, :complete)
    end

    test "returns :default when the phase has no handler" do
      w = %Workflow{name: "t", phases: [%Phase{id: "p", next: "end"}]}
      m = insert_mission!(%{current_phase: "p"})
      assert :default = Advancer.invoke_terminal(m, w, :complete)
    end
  end
end
