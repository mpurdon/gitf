defmodule GiTF.Dashboard.InputGatePipelineTest do
  @moduledoc """
  A mission blocked on a human must be visibly blocked on a human. That
  is the lesson msn-ac0539 cost twelve hours to learn on the approval
  gate — the one phase meaning "the factory has stopped" was drawn as
  the factory merging — and the input gate must not reintroduce it in a
  new shape.

  The new shape it COULD take is positional. `awaiting_input` has no real
  place in the pipeline: any phase raises it and the mission returns to
  that same phase. Driving progress from its index would render a
  mission held during `design` as either finished (gate placed late) or
  never started (gate placed early). So the widgets resolve a held
  mission's position from `input_return_phase`, and the gate step itself
  is drawn from `GiTF.Inquiry.gate_state/1`.

  These assert against rendered step classes, because the class is what
  the operator actually sees.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.{Archive, Inquiry}

  @endpoint GiTF.Web.Endpoint

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    endpoint_alive? =
      case Process.whereis(GiTF.Web.Endpoint) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    ets_ok? =
      try do
        GiTF.Web.Endpoint.config(:pubsub_server)
        true
      rescue
        ArgumentError -> false
      end

    if !(endpoint_alive? and ets_ok?) do
      GiTF.Test.StoreHelper.safe_stop(GiTF.Web.Endpoint)
      Process.sleep(50)
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    :ok
  end

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "input-gate",
            goal: "render the input gate",
            status: "active",
            sector_id: "no-such-sector",
            artifacts: %{},
            ops: []
          },
          fields
        )
      )

    m
  end

  defp ask!(mission_id, phase \\ "design") do
    {:ok, inquiry, :asked} =
      Inquiry.ask(mission_id, %{
        key: "layout",
        phase: phase,
        kind: :choice,
        prompt: "Which layout?",
        options: [%{id: "grid", label: "Grid", rationale: "Denser"}, %{id: "list", label: "List"}]
      })

    inquiry
  end

  defp render_pipeline(mission) do
    {:ok, _view, html} = live(build_conn(), "/dashboard/missions/#{mission.id}")
    html
  end

  defp step_class(html, phase) do
    case Regex.run(~r/class="step ([^"]*)"[^>]*phx-value-phase="#{phase}"/, html) do
      [_, classes] -> String.trim(classes)
      nil -> nil
    end
  end

  describe "the gate is on the strip at all" do
    test "awaiting_input renders as its own step, labelled input" do
      html = render_pipeline(mission!(%{current_phase: "validation"}))

      assert html =~ ~s{phx-value-phase="awaiting_input"}
      assert html =~ ~r/class="step-label"[^>]*>\s*input/
    end

    test "every orchestrator phase still has a step" do
      html = render_pipeline(mission!(%{current_phase: "validation"}))

      for phase <- GiTF.Major.Orchestrator.phases() do
        assert html =~ ~s{phx-value-phase="#{phase}"}, "#{phase} is missing from the pipeline"
      end
    end
  end

  describe "a mission held for an answer" do
    setup do
      mission =
        mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})

      ask!(mission.id)

      %{mission: mission, html: render_pipeline(mission)}
    end

    test "input is the ACTIVE step", %{html: html} do
      assert step_class(html, "awaiting_input") == "step-active"
    end

    test "the mission reads as being AT design, not past it", %{html: html} do
      # It is held during design and returns to design. Rendering design as
      # done would say the phase produced something usable; it produced a
      # question.
      refute step_class(html, "design") == "step-done"
      refute step_class(html, "review") == "step-done"
    end

    test "nothing downstream is claimed as done", %{html: html} do
      for phase <- ~w(planning implementation validation sync publish) do
        assert step_class(html, phase) == "step-future", "#{phase} should be future"
      end
    end

    test "the derivation both widgets share says HELD", %{mission: mission} do
      assert Inquiry.gate_state(Archive.get(:missions, mission.id)) == :held
    end

    test "the page says the mission is holding and shows the question", %{html: html} do
      assert html =~ "Operator questions"
      assert html =~ "Which layout?"
      assert html =~ "Grid"
      assert html =~ "Denser"
      assert html =~ "will not move until"
    end

    test "the question is answerable from the mission page", %{html: html} do
      assert html =~ ~s{phx-click="answer_inquiry"}
      assert html =~ ~s{phx-value-answer="grid"}
    end
  end

  describe "a mission that asked and was answered" do
    setup do
      mission = mission!(%{current_phase: "implementation", input_return_phase: "design"})
      inquiry = ask!(mission.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      %{mission: mission, html: render_pipeline(mission)}
    end

    test "the gate reads DONE, not pending forever", %{html: html} do
      # It can never be "done" by position — the mission returned to a
      # phase BEFORE it — so asked-and-answered is the only meaning.
      assert step_class(html, "awaiting_input") == "step-done"
    end

    test "the answer and who gave it are on the page", %{html: html} do
      assert html =~ "answered"
      assert html =~ "operator"
    end

    test "the mission's real position is unaffected", %{html: html} do
      assert step_class(html, "implementation") == "step-active"
    end
  end

  describe "a mission that never asked anything" do
    test "the gate is FUTURE while the mission is live — never dimmed" do
      mission = mission!(%{current_phase: "implementation"})

      assert step_class(render_pipeline(mission), "awaiting_input") == "step-future"
    end

    test "the gate is SKIPPED once the mission is finished" do
      mission = mission!(%{current_phase: "completed", status: "completed"})

      assert step_class(render_pipeline(mission), "awaiting_input") == "step-skipped"
    end

    test "a failed mission is skipped too — it is not waiting for anything" do
      mission = mission!(%{current_phase: "failed", status: "failed"})

      assert step_class(render_pipeline(mission), "awaiting_input") == "step-skipped"
    end

    test "the questions panel is absent entirely" do
      mission = mission!(%{current_phase: "implementation"})

      refute render_pipeline(mission) =~ "Operator questions"
    end
  end

  describe "the Questions queue" do
    test "says plainly that nothing auto-answers when it is empty" do
      {:ok, _view, html} = live(build_conn(), "/dashboard/questions")

      assert html =~ "No missions are waiting on you"
      assert html =~ "auto-answers"
    end

    test "lists a held mission with its goal and its options" do
      mission = mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})
      ask!(mission.id)

      {:ok, _view, html} = live(build_conn(), "/dashboard/questions")

      assert html =~ "Which layout?"
      assert html =~ "render the input gate"
      assert html =~ mission.id
      assert html =~ "Denser"
    end

    test "answering from the queue records the decision" do
      mission = mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})
      inquiry = ask!(mission.id)

      {:ok, view, _html} = live(build_conn(), "/dashboard/questions")

      view
      |> element(~s{button[phx-click="answer_inquiry"][phx-value-answer="list"]})
      |> render_click()

      assert Inquiry.status(inquiry.id) == :answered
      assert Inquiry.get(inquiry.id).answer == "list"
    end

    # phoenix_live_view's `extractMeta` copies the clicked element's native
    # `el.value` into the params AFTER the phx-value-* attributes, and a
    # <button> with no value attribute reports "". A real click therefore
    # arrives as {"value" => "", ...} on top of whatever phx-value-* named.
    # `render_click/1` never simulates that, which is how the original
    # `phx-value-value` shipped green and failed on the first real click
    # (inq-acd882, 2026-08-31). The answer must ride under a key the
    # browser cannot clobber, and "" must never be read as an answer.
    test "a browser-shaped click carrying an empty native value still records the option" do
      mission = mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})
      inquiry = ask!(mission.id)

      {:ok, view, _html} = live(build_conn(), "/dashboard/questions")

      render_click(view, "answer_inquiry", %{
        "id" => inquiry.id,
        "answer" => "list",
        "value" => ""
      })

      assert Inquiry.get(inquiry.id).answer == "list"
    end

    test "a browser-shaped click on a text question answers from the draft, not the empty value" do
      mission = mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})

      {:ok, inquiry, :asked} =
        Inquiry.ask(mission.id, %{key: "name", phase: "design", kind: :text, prompt: "Name it?"})

      {:ok, view, _html} = live(build_conn(), "/dashboard/questions")

      render_change(view, "draft_answer", %{"id" => inquiry.id, "value" => "priority-rail"})
      render_click(view, "answer_inquiry", %{"id" => inquiry.id, "value" => ""})

      assert Inquiry.get(inquiry.id).answer == "priority-rail"
    end

    test "an answered question leaves the queue" do
      mission = mission!(%{current_phase: "awaiting_input", input_return_phase: "design"})
      inquiry = ask!(mission.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")

      {:ok, _view, html} = live(build_conn(), "/dashboard/questions")

      assert html =~ "No missions are waiting on you"
    end
  end
end
