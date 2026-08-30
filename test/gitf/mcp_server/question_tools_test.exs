defmodule GiTF.MCPServer.QuestionToolsTest do
  @moduledoc """
  The MCP is the primary control surface for this factory, so a mission
  that stops mid-run to ask the operator something has to be answerable
  here. If it were only answerable on the Catwalk, the input gate would
  be a coverage bug the day it shipped — `docs/MCP.md`'s standard.

  Same confirm-gating, receipt shape and `@mcp_actor` attribution as the
  approval trio. Two differences carry the design: an answer is not
  binary, and answering sends the mission BACKWARDS to the phase that
  asked so the decision shapes what gets built.
  """
  use GiTF.StoreCase

  alias GiTF.MCPServer.{Handlers, Tools}
  alias GiTF.{Archive, Inquiry}

  defp mission!(fields \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "questions-mcp",
            goal: "pick a layout for the settings page",
            status: "active",
            sector_id: "no-such-sector",
            current_phase: "awaiting_input",
            input_return_phase: "design",
            artifacts: %{},
            ops: []
          },
          fields
        )
      )

    m
  end

  defp ask!(mission_id, overrides \\ %{}) do
    {:ok, inquiry, :asked} =
      Inquiry.ask(
        mission_id,
        Map.merge(
          %{
            key: "layout",
            phase: "design",
            kind: :choice,
            prompt: "Which layout for the settings page?",
            options: [
              %{id: "grid", label: "Grid", rationale: "Denser, harder to scan"},
              %{id: "list", label: "List", rationale: "Scannable, more scrolling"}
            ]
          },
          overrides
        )
      )

    inquiry
  end

  defp decode({:ok, json}), do: Jason.decode!(json)

  describe "the tools are declared" do
    test "all three are in the manifest" do
      names = Tools.all() |> Enum.map(& &1.name)

      assert "list_questions" in names
      assert "show_question" in names
      assert "answer_question" in names
    end

    test "answer_question is a gated write" do
      tool = Enum.find(Tools.all(), &(&1.name == "answer_question"))

      assert tool.description =~ "[WRITE]"
      assert "confirm" in tool.inputSchema.required
      assert "answer" in tool.inputSchema.required
    end

    test "the reads are not gated" do
      for name <- ["list_questions", "show_question"] do
        tool = Enum.find(Tools.all(), &(&1.name == name))
        refute "confirm" in tool.inputSchema.required
      end
    end
  end

  describe "list_questions" do
    test "an empty list is PROOF nothing is stopped on the operator" do
      body = decode(Handlers.call("list_questions", %{}))

      assert body["count"] == 0
      assert body["note"] =~ "never auto-answers"
    end

    test "open questions come back with their options and rationale" do
      m = mission!()
      ask!(m.id)

      body = decode(Handlers.call("list_questions", %{}))

      assert body["count"] == 1
      assert [q] = body["questions"]
      assert q["mission_id"] == m.id
      assert q["phase"] == "design"
      assert q["kind"] == "choice"
      assert [grid, list] = q["options"]
      assert grid["id"] == "grid"
      assert grid["rationale"] =~ "Denser"
      assert list["id"] == "list"
    end

    test "the note says the mission is STOPPED, not merely waiting" do
      m = mission!()
      ask!(m.id)

      assert decode(Handlers.call("list_questions", %{}))["note"] =~ "STOPPED"
    end

    test "mission_id narrows it" do
      a = mission!()
      b = mission!()
      ask!(a.id)
      ask!(b.id)

      body = decode(Handlers.call("list_questions", %{"mission_id" => a.id}))

      assert body["count"] == 1
      assert [%{"mission_id" => id}] = body["questions"]
      assert id == a.id
    end

    test "answered questions are excluded by default and included on request" do
      m = mission!()
      inquiry = ask!(m.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")

      assert decode(Handlers.call("list_questions", %{}))["count"] == 0

      body = decode(Handlers.call("list_questions", %{"answered" => true}))
      assert body["count"] == 1
      assert body["open"] == 0
    end
  end

  describe "show_question" do
    test "an unknown id is a clear miss" do
      assert {:error, message} = Handlers.call("show_question", %{"id" => "inq-nope"})
      assert message =~ "not found"
    end

    test "carries what the operator needs to decide without reading code" do
      m = mission!()
      inquiry = ask!(m.id)

      body = decode(Handlers.call("show_question", %{"id" => inquiry.id}))

      assert body["prompt"] =~ "settings page"
      assert body["mission_goal"] =~ "settings page"
      assert body["mission_phase"] == "awaiting_input"
      assert body["returns_to"] == "design"
      assert body["budget_remaining"] >= 0
      assert body["note"] =~ "option ID"
    end

    test "an answered question says the first answer stands" do
      m = mission!()
      inquiry = ask!(m.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "list", answered_by: "operator")

      body = decode(Handlers.call("show_question", %{"id" => inquiry.id}))

      assert body["status"] == "answered"
      assert body["answer"] == "list"
      assert body["answer_label"] == "List"
      assert body["answered_by"] == "operator"
      assert body["note"] =~ "first answer stands"
    end
  end

  describe "answer_question" do
    test "refuses without confirm" do
      m = mission!()
      inquiry = ask!(m.id)

      assert {:error, message} =
               Handlers.call("answer_question", %{"id" => inquiry.id, "answer" => "grid"})

      assert message =~ "confirm: true"
      assert Inquiry.status(inquiry.id) == :open
    end

    test "records the answer and says the mission re-RUNS the asking phase" do
      m = mission!()
      inquiry = ask!(m.id)

      body =
        decode(
          Handlers.call("answer_question", %{
            "id" => inquiry.id,
            "answer" => "grid",
            "confirm" => true
          })
        )

      assert body["answered"] == true
      assert body["answer"] == "grid"
      assert body["answered_by"] == "mcp_operator"
      assert body["resumes_phase"] == "design"
      assert body["note"] =~ "RE-RUNS"
      assert body["note"] =~ "survives a resume"

      assert Inquiry.status(inquiry.id) == :answered
    end

    test "an unknown option is refused and names the valid ids" do
      m = mission!()
      inquiry = ask!(m.id)

      assert {:error, message} =
               Handlers.call("answer_question", %{
                 "id" => inquiry.id,
                 "answer" => "carousel",
                 "confirm" => true
               })

      assert message =~ "grid"
      assert message =~ "list"
      assert Inquiry.status(inquiry.id) == :open
    end

    test "an already-answered question is an ANSWER, not an error" do
      m = mission!()
      inquiry = ask!(m.id)
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      body =
        decode(
          Handlers.call("answer_question", %{
            "id" => inquiry.id,
            "answer" => "list",
            "confirm" => true
          })
        )

      assert body["answered"] == false
      assert body["answer"] == "grid"
      assert body["answered_by"] == "operator"
      assert body["note"] =~ "FIRST answer stands"
    end

    test "an unknown id is a clear miss" do
      assert {:error, message} =
               Handlers.call("answer_question", %{
                 "id" => "inq-nope",
                 "answer" => "grid",
                 "confirm" => true
               })

      assert message =~ "not found"
    end

    test "missing parameters name themselves" do
      assert {:error, message} = Handlers.call("answer_question", %{"id" => "inq-x"})
      assert message =~ "answer"

      assert {:error, message} = Handlers.call("answer_question", %{})
      assert message =~ "id"
    end

    test "the write is audit-logged with the actual decision" do
      m = mission!()
      inquiry = ask!(m.id)

      Handlers.call("answer_question", %{
        "id" => inquiry.id,
        "answer" => "grid",
        "confirm" => true
      })

      entry =
        GiTF.Archive.all(:audit_log)
        |> Enum.find(&(&1[:action] == "inquiry.answer"))

      assert entry
      assert entry[:subject] == m.id
      assert entry[:details][:answer] == "grid"
    end
  end
end
