defmodule GiTF.Inquiry.GateTest do
  @moduledoc """
  The seam: a phase artifact carrying `questions` becomes a held mission,
  and an answered question becomes a re-dispatched phase.

  Three things here are load-bearing and none of them are obvious:

    * The interception sits ABOVE the workflow/legacy fork, because any
      phase can ask and a workflow YAML that never declared
      `awaiting_input` would send its held missions down the Advancer's
      WORKFLOW DRIFT path.
    * The asking phase's artifact is MOVED ASIDE when the mission holds.
      Leave it in place and `check_and_advance/3` walks straight past to
      the next phase the moment the mission returns — the answer would be
      recorded and nothing would ever be built with it.
    * A question that cannot be answered is refused at the seam and the
      phase carries on. Parking a mission on an unanswerable prompt is
      the single worst outcome this machinery can produce.
  """
  use GiTF.StoreCase

  alias GiTF.Inquiry.Gate
  alias GiTF.{Archive, Inquiry, Missions}

  defp mission!(fields \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "gate",
            goal: "pick a thing",
            status: "active",
            sector_id: "no-such-sector",
            current_phase: "design",
            artifacts: %{},
            ops: []
          },
          fields
        )
      )

    m
  end

  defp question(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "layout",
        "kind" => "choice",
        "prompt" => "Which layout?",
        "options" => [
          %{"id" => "grid", "label" => "Grid", "rationale" => "Denser"},
          %{"id" => "list", "label" => "List", "rationale" => "Scannable"}
        ]
      },
      overrides
    )
  end

  defp artifact(questions), do: %{"components" => [], "questions" => questions}

  defp reload(mission), do: Archive.get(:missions, mission.id)

  describe "nothing to ask" do
    test "an artifact with no questions clears" do
      m = mission!(%{artifacts: %{"design" => %{"components" => []}}})
      assert Gate.intercept(reload(m)) == :clear
    end

    test "a mission with no artifacts at all clears" do
      assert Gate.intercept(reload(mission!())) == :clear
    end

    test "a phase that may not ask is never intercepted" do
      # A `questions` key on a sync artifact is a bug in something else,
      # and by then the decision has been built either way.
      m =
        mission!(%{
          current_phase: "sync",
          artifacts: %{"sync" => artifact([question()])}
        })

      assert Gate.intercept(reload(m)) == :clear
    end

    test "a malformed questions value does not take the advance loop down" do
      m = mission!(%{artifacts: %{"design" => %{"questions" => "please advise"}}})
      assert Gate.intercept(reload(m)) == :clear
    end
  end

  # Rendering happens HERE and nowhere later. The mockup lives in the
  # asking ghost's worktree, and worktrees are reaped on completion and
  # swept when they go orphan, so the interception is the last moment the
  # source is guaranteed to exist. It sits after validation because
  # validation is pure and there is no reason to spawn a browser for a
  # question that is about to be refused as unanswerable.
  describe "rendering mockups at the seam" do
    defmodule SeamRenderer do
      def render_file(source, output, _opts) do
        send(self(), {:rendered, source})
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, "PNG")
        {:ok, output}
      end
    end

    defmodule BrokenRenderer do
      def render_file(_source, _output, _opts), do: {:error, :timeout}
    end

    setup do
      root = Path.join(System.tmp_dir!(), "gitf_gate_prev_#{:erlang.unique_integer([:positive])}")

      worktree =
        Path.join(System.tmp_dir!(), "gitf_gate_wt_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(worktree, "mockups"))
      File.write!(Path.join(worktree, "mockups/a.html"), "<p>bars</p>")

      previous = %{
        root: Application.get_env(:gitf, :visual_screenshots_root),
        capture: Application.get_env(:gitf, :visual_capture_enabled),
        renderer: Application.get_env(:gitf, :inquiry_preview_renderer)
      }

      Application.put_env(:gitf, :visual_screenshots_root, root)
      Application.put_env(:gitf, :visual_capture_enabled, true)
      Application.put_env(:gitf, :inquiry_preview_renderer, SeamRenderer)

      on_exit(fn ->
        Enum.each(
          [
            {:visual_screenshots_root, previous.root},
            {:visual_capture_enabled, previous.capture},
            {:inquiry_preview_renderer, previous.renderer}
          ],
          fn
            {key, nil} -> Application.delete_env(:gitf, key)
            {key, value} -> Application.put_env(:gitf, key, value)
          end
        )

        File.rm_rf(root)
        File.rm_rf(worktree)
      end)

      {:ok, shell} =
        Archive.insert(:shells, %{
          sector_id: "no-such-sector",
          worktree_path: worktree,
          branch: "ghost/g1",
          status: "active"
        })

      {:ok, ghost} =
        Archive.insert(:ghosts, %{
          shell_id: shell.id,
          sector_id: "no-such-sector",
          status: "running"
        })

      ops = [
        %{
          id: "op1",
          phase_job: true,
          phase: "design",
          ghost_id: ghost.id,
          status: "done",
          inserted_at: DateTime.utc_now()
        }
      ]

      previewed =
        question(%{
          "options" => [
            %{"label" => "Bars", "rationale" => "Magnitude", "preview" => "mockups/a.html"},
            %{"label" => "Dots", "rationale" => "Category"}
          ]
        })

      %{ops: ops, previewed: previewed, worktree: worktree}
    end

    test "an option with a mockup is rendered and the reference is stored", ctx do
      m = mission!(%{ops: ctx.ops, artifacts: %{"design" => artifact([ctx.previewed])}})

      assert {:held, "design"} = Gate.intercept(reload(m))
      assert_received {:rendered, _}

      assert [inquiry] = Inquiry.list_open(m.id)
      assert [bars, dots] = inquiry.options
      assert File.regular?(bars.preview.png)
      assert dots.preview == nil
    end

    test "a failed render still holds the mission and asks as text", ctx do
      Application.put_env(:gitf, :inquiry_preview_renderer, BrokenRenderer)
      m = mission!(%{ops: ctx.ops, artifacts: %{"design" => artifact([ctx.previewed])}})

      # The whole point: a broken picture costs the operator context, never
      # the question. A mission that failed to ask because a mockup did not
      # render would be the factory deciding by accident.
      assert {:held, "design"} = Gate.intercept(reload(m))

      assert [inquiry] = Inquiry.list_open(m.id)
      assert [bars, _] = inquiry.options
      assert bars.preview == nil
      assert bars.preview_error =~ "timed out"
      assert bars.label == "Bars"
      assert bars.rationale == "Magnitude"
    end

    test "an unanswerable question is refused BEFORE the browser is spawned", ctx do
      one_option =
        question(%{"options" => [%{"label" => "Bars", "preview" => "mockups/a.html"}]})

      m = mission!(%{ops: ctx.ops, artifacts: %{"design" => artifact([one_option])}})

      assert Gate.intercept(reload(m)) == :clear
      refute_received {:rendered, _}
    end
  end

  describe "holding" do
    setup do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})
      result = Gate.intercept(reload(m))
      %{mission: m, result: result}
    end

    test "the mission holds and names the phase it came from", %{result: result} do
      assert result == {:held, "design"}
    end

    test "it is at awaiting_input, and says which phase it returns to", %{mission: m} do
      held = reload(m)

      assert held.current_phase == "awaiting_input"
      assert held.input_return_phase == "design"
    end

    test "the question is open and readable", %{mission: m} do
      assert [inquiry] = Inquiry.list_open(m.id)
      assert inquiry.phase == "design"
      assert inquiry.key == "layout"
      assert inquiry.prompt == "Which layout?"
      assert [%{id: "grid"}, %{id: "list"}] = inquiry.options
    end

    test "the artifact is MOVED ASIDE so the ladder cannot walk past it", %{mission: m} do
      held = reload(m)

      refute Map.has_key?(held.artifacts, "design")
      assert %{"questions" => _} = held.artifacts["design_asked"]
      assert held.artifacts["design_asked"]["held_for_input_at"]
    end

    test "both pipeline widgets agree the mission is held", %{mission: m} do
      assert Inquiry.gate_state(reload(m)) == :held
    end

    test "a second intercept on the held mission does nothing new", %{mission: m} do
      # The artifact is gone from the canonical key, and the phase is no
      # longer askable — a sweep must not re-open anything.
      assert Gate.intercept(reload(m)) == :clear
      assert length(Inquiry.list(m.id)) == 1
    end
  end

  describe "a variant phase asking" do
    test "a suffixed artifact key is in the phase's family" do
      m = mission!(%{artifacts: %{"design_minimal" => artifact([question()])}})

      assert {:held, "design"} = Gate.intercept(reload(m))
      assert [inquiry] = Inquiry.list_open(m.id)
      assert inquiry.phase == "design"
      assert reload(m).artifacts["design_minimal_asked"]
    end
  end

  describe "a question that cannot be answered" do
    test "is refused, the mission is NOT held, and the phase carries on" do
      m =
        mission!(%{
          artifacts: %{"design" => artifact([question(%{"options" => [%{"label" => "Only"}]})])}
        })

      assert Gate.intercept(reload(m)) == :clear

      held = reload(m)
      assert held.current_phase == "design"
      assert Inquiry.list(m.id) == []
    end

    test "the refusal is written onto the artifact where an operator will see it" do
      m = mission!(%{artifacts: %{"design" => artifact([question(%{"prompt" => ""})])}})

      Gate.intercept(reload(m))

      assert [reason] = reload(m).artifacts["design"]["questions_rejected"]
      assert reason =~ "prompt cannot be blank"
    end

    test "the artifact is left in place — a refused question must not stall the phase" do
      m = mission!(%{artifacts: %{"design" => artifact([question(%{"prompt" => ""})])}})

      Gate.intercept(reload(m))

      assert Map.has_key?(reload(m).artifacts, "design")
      refute Map.has_key?(reload(m).artifacts, "design_asked")
    end

    test "one bad question among good ones still holds for the good ones" do
      m =
        mission!(%{
          artifacts: %{
            "design" => artifact([question(), question(%{"key" => "", "prompt" => "?"})])
          }
        })

      assert {:held, "design"} = Gate.intercept(reload(m))
      assert [inquiry] = Inquiry.list_open(m.id)
      assert inquiry.key == "layout"
    end
  end

  describe "while held" do
    setup do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})
      {:held, _} = Gate.intercept(reload(m))
      %{mission: m}
    end

    test "handle_result keeps holding and answers nothing", %{mission: m} do
      assert {:ok, "awaiting_input"} = Gate.handle_result(reload(m))

      assert reload(m).current_phase == "awaiting_input"
      assert [%{status: "open"}] = Inquiry.list(m.id)
    end

    test "holding is stable across repeated advance sweeps", %{mission: m} do
      for _ <- 1..5, do: Gate.handle_result(reload(m))

      assert reload(m).current_phase == "awaiting_input"
      assert [%{status: "open"}] = Inquiry.list(m.id)
    end
  end

  describe "answered — the round trip" do
    setup do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})
      {:held, _} = Gate.intercept(reload(m))
      [inquiry] = Inquiry.list_open(m.id)
      %{mission: m, inquiry: inquiry}
    end

    test "the mission returns to the phase that asked", %{mission: m, inquiry: inquiry} do
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      Gate.handle_result(reload(m))

      assert reload(m).current_phase == "design"
    end

    test "the answer reaches the re-run phase's prompt", %{mission: m, inquiry: inquiry} do
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      block = Inquiry.prompt_block(m.id)
      assert block =~ "Which layout?"
      assert block =~ "Grid"
    end

    test "the gate reads ANSWERED, not held and not skipped", %{mission: m, inquiry: inquiry} do
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")
      Gate.handle_result(reload(m))

      assert Inquiry.gate_state(reload(m)) == :answered
    end

    test "the transition log says why it moved", %{mission: m, inquiry: inquiry} do
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")
      Gate.handle_result(reload(m))

      reasons = m.id |> Missions.get_phase_transitions() |> Enum.map(& &1.reason)

      assert Enum.any?(reasons, &(&1 =~ "asked the operator"))
      assert Enum.any?(reasons, &(&1 =~ "operator answered"))
    end

    test "two questions hold until BOTH are answered" do
      m =
        mission!(%{
          artifacts: %{"design" => artifact([question(), question(%{"key" => "palette"})])}
        })

      {:held, _} = Gate.intercept(reload(m))
      [first, second] = Inquiry.list_open(m.id)

      {:ok, _, :answered} = Inquiry.answer(first.id, "grid")
      assert {:ok, "awaiting_input"} = Gate.handle_result(reload(m))
      assert reload(m).current_phase == "awaiting_input"

      {:ok, _, :answered} = Inquiry.answer(second.id, "grid")
      Gate.handle_result(reload(m))
      assert reload(m).current_phase == "design"
    end
  end

  describe "a held mission with no recorded return phase" do
    test "falls back to the last non-gate phase rather than guessing" do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})
      {:held, _} = Gate.intercept(reload(m))
      [inquiry] = Inquiry.list_open(m.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")

      # Simulate a record written before `input_return_phase` existed.
      Archive.update(:missions, m.id, &Map.delete(&1, :input_return_phase))

      Gate.handle_result(reload(m))

      assert reload(m).current_phase == "design"
    end

    test "holds and pages rather than routing a mission it cannot place" do
      m =
        mission!(%{
          current_phase: "awaiting_input",
          artifacts: %{}
        })

      assert {:ok, "awaiting_input"} = Gate.handle_result(reload(m))
      assert reload(m).current_phase == "awaiting_input"
    end
  end

  describe "through advance_quest/1 — the real entry point" do
    test "a question raised by a phase holds the mission on the very next advance" do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})

      assert {:ok, "awaiting_input"} = GiTF.Major.Orchestrator.advance_quest(m.id)
      assert reload(m).current_phase == "awaiting_input"
      assert [%{status: "open"}] = Inquiry.list(m.id)
    end

    test "repeated advances do not walk the mission past its own question" do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})

      for _ <- 1..3, do: GiTF.Major.Orchestrator.advance_quest(m.id)

      assert reload(m).current_phase == "awaiting_input"
      assert length(Inquiry.list(m.id)) == 1
    end

    test "answering releases it back to the asking phase" do
      m = mission!(%{artifacts: %{"design" => artifact([question()])}})
      {:ok, "awaiting_input"} = GiTF.Major.Orchestrator.advance_quest(m.id)
      [inquiry] = Inquiry.list_open(m.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      GiTF.Major.Orchestrator.advance_quest(m.id)

      assert reload(m).current_phase == "design"
    end

    test "a mission with no question advances as it always did" do
      m = mission!(%{artifacts: %{"design" => %{"components" => []}}})

      GiTF.Major.Orchestrator.advance_quest(m.id)

      refute reload(m).current_phase == "awaiting_input"
    end
  end

  describe "the gate is excluded from every mechanism that would punish waiting" do
    # Four mechanisms have to know that a held mission is not a broken
    # one, and each is wrong in a way that costs something real. They read
    # ONE list so a third gate cannot silently miss one of them.
    test "awaiting_input is a declared human gate" do
      assert "awaiting_input" in Missions.human_gate_phases()
      assert "awaiting_approval" in Missions.human_gate_phases()
    end

    test "a held mission reads as held for a human" do
      m = mission!(%{current_phase: "awaiting_input"})
      assert Missions.held_for_human?(reload(m))
    end

    test "Tachikoma's stall detector skips it — a held mission has no live ghost BY DESIGN" do
      m = mission!(%{current_phase: "awaiting_input"})

      # The stall sweep filters active missions and then rejects the human
      # gates. Without the rejection this mission — active, no ghost, no op
      # activity — is exactly the shape it pages about.
      assert reload(m).status in Missions.active_statuses()
      assert Missions.held_for_human?(reload(m))
    end

    test "the mission age cap does not force-complete it for the operator being asleep" do
      old = DateTime.add(DateTime.utc_now(), -100 * 3600, :second)
      m = mission!(%{current_phase: "awaiting_input", inserted_at: old})

      refute GiTF.Major.Lifecycle.quest_timed_out?(reload(m))
    end

    test "the budget cap has nothing to say about a mission that is spending nothing" do
      m = mission!(%{current_phase: "awaiting_input", cost_cap_usd: 0.0})

      refute GiTF.Major.Lifecycle.over_budget?(reload(m))
    end
  end

  describe "start/1 — the workflow entry" do
    test "refuses to park a mission that has nothing open" do
      m = mission!()
      assert {:error, :no_open_inquiry} = Gate.start(reload(m))
      assert reload(m).current_phase == "design"
    end

    test "parks a mission that does" do
      m = mission!()
      {:ok, _, :asked} = Inquiry.ask(m.id, %{key: "k", phase: "design", kind: :text, prompt: "?"})

      assert {:ok, "awaiting_input"} = Gate.start(reload(m))
      assert reload(m).current_phase == "awaiting_input"
    end
  end
end
