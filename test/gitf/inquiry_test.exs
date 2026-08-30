defmodule GiTF.InquiryTest do
  @moduledoc """
  The input gate's core contract.

  Until it existed the factory could stop for a human in exactly one
  place — `awaiting_approval`, binary, at the very end — so any work
  containing genuine taste either got guessed at and reviewed ninety
  minutes later or never went through the factory at all.

  Three properties carry the whole design and each has its own describe
  block below: a question is idempotent on `{phase, key}` (or a
  re-dispatched phase re-asks forever), the first answer wins (or work
  is re-dispatched against a decision that then changes underneath it),
  and a malformed question is refused at the seam (or a mission parks
  on a prompt no human can act on, which is the worst thing this module
  can produce).
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Inquiry}

  setup do
    previous = GiTF.Config.Provider.get([:inquiries])
    on_exit(fn -> GiTF.Config.Provider.put([:inquiries], previous) end)
    :ok
  end

  defp mission!(fields \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "inquiry",
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

  defp choice(overrides \\ %{}) do
    Map.merge(
      %{
        key: "layout",
        phase: "design",
        kind: :choice,
        prompt: "Which layout?",
        options: [
          %{id: "grid", label: "Grid", rationale: "Denser, harder to scan"},
          %{id: "list", label: "List", rationale: "Scannable, more scrolling"}
        ]
      },
      overrides
    )
  end

  describe "validating a question at the seam" do
    test "a blank prompt is refused" do
      assert {:error, {:invalid, reason}} = Inquiry.validate(choice(%{prompt: "   "}))
      assert reason =~ "prompt cannot be blank"
    end

    test "a missing prompt is refused" do
      assert {:error, {:invalid, reason}} =
               Inquiry.validate(Map.delete(choice(), :prompt))

      assert reason =~ "prompt is required"
    end

    test "a missing key is refused — prompt text is not an identity" do
      assert {:error, {:invalid, reason}} = Inquiry.validate(Map.delete(choice(), :key))
      assert reason =~ "key is required"
    end

    test "a :choice with one option is not a question" do
      one = choice(%{options: [%{id: "a", label: "Only"}]})

      assert {:error, {:invalid, reason}} = Inquiry.validate(one)
      assert reason =~ "at least 2 options"
    end

    test "a :choice with no options list is refused" do
      assert {:error, {:invalid, reason}} = Inquiry.validate(Map.delete(choice(), :options))
      assert reason =~ "options list"
    end

    test "an option with a blank label is refused" do
      blank = choice(%{options: [%{id: "a", label: ""}, %{id: "b", label: "B"}]})

      assert {:error, {:invalid, reason}} = Inquiry.validate(blank)
      assert reason =~ "non-empty label"
    end

    test "duplicate option ids are refused" do
      dupe = choice(%{options: [%{id: "a", label: "One"}, %{id: "a", label: "Two"}]})

      assert {:error, {:invalid, reason}} = Inquiry.validate(dupe)
      assert reason =~ "unique"
    end

    test "an unknown kind is refused and names the valid ones" do
      assert {:error, {:invalid, reason}} = Inquiry.validate(choice(%{kind: :essay}))
      assert reason =~ ":choice"
      assert reason =~ ":confirm"
    end

    test "a string kind from JSON is accepted and normalized to an atom" do
      assert {:ok, %{kind: :choice}} = Inquiry.validate(choice(%{kind: "choice"}))
    end

    test "an option id is derived from its label when absent" do
      derived = choice(%{options: [%{label: "Two Column"}, %{label: "One Column"}]})

      assert {:ok, %{options: [first, second]}} = Inquiry.validate(derived)
      assert first.id == "two-column"
      assert second.id == "one-column"
    end

    test ":text and :confirm need no options" do
      assert {:ok, _} = Inquiry.validate(%{key: "n", phase: "design", kind: :text, prompt: "?"})

      assert {:ok, _} =
               Inquiry.validate(%{key: "n", phase: "design", kind: :confirm, prompt: "?"})
    end
  end

  describe "asking" do
    test "a valid question opens and the mission has something to hold for" do
      m = mission!()

      assert {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      assert inquiry.status == "open"
      assert inquiry.phase == "design"
      assert Inquiry.open?(m.id)
      assert Inquiry.status(inquiry.id) == :open
    end

    test "a malformed question records nothing at all" do
      m = mission!()

      assert {:error, {:invalid, _}} = Inquiry.ask(m.id, choice(%{prompt: ""}))
      assert Inquiry.list(m.id) == []
      refute Inquiry.open?(m.id)
    end

    test "re-asking the same {phase, key} returns the OPEN question, not a second one" do
      m = mission!()

      assert {:ok, first, :asked} = Inquiry.ask(m.id, choice())
      assert {:ok, second, :open} = Inquiry.ask(m.id, choice())

      assert first.id == second.id
      assert length(Inquiry.list(m.id)) == 1
    end

    test "re-asking an ANSWERED question returns the answer — this is the loop breaker" do
      # A re-dispatched phase runs again and can ask again. If that opened
      # a second question the mission would hold forever, one question at
      # a time, and only the budget would stop it.
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "test")

      assert {:ok, answered, :already_answered} = Inquiry.ask(m.id, choice())
      assert answered.answer == "grid"
      assert length(Inquiry.list(m.id)) == 1
    end

    test "a reworded prompt with the same key is the same question" do
      m = mission!()
      {:ok, first, :asked} = Inquiry.ask(m.id, choice())

      assert {:ok, same, :open} = Inquiry.ask(m.id, choice(%{prompt: "Which layout, really?"}))
      assert same.id == first.id
    end

    test "the same key in a DIFFERENT phase is a different question" do
      m = mission!()
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())

      assert {:ok, _, :asked} = Inquiry.ask(m.id, choice(%{phase: "planning"}))
      assert length(Inquiry.list(m.id)) == 2
    end
  end

  describe "the per-mission budget" do
    test "the question past the budget is refused, and the phase is left to decide" do
      GiTF.Config.Provider.put([:inquiries], %{max_per_mission: 2})
      m = mission!()

      assert {:ok, _, :asked} = Inquiry.ask(m.id, choice(%{key: "one"}))
      assert {:ok, _, :asked} = Inquiry.ask(m.id, choice(%{key: "two"}))
      assert {:error, {:budget_exhausted, 2}} = Inquiry.ask(m.id, choice(%{key: "three"}))

      assert length(Inquiry.list(m.id)) == 2
    end

    test "budget_remaining counts down and floors at zero" do
      GiTF.Config.Provider.put([:inquiries], %{max_per_mission: 1})
      m = mission!()

      assert Inquiry.budget_remaining(m.id) == 1
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())
      assert Inquiry.budget_remaining(m.id) == 0
    end

    test "budget is per mission, not factory-wide" do
      GiTF.Config.Provider.put([:inquiries], %{max_per_mission: 1})
      a = mission!()
      b = mission!()

      assert {:ok, _, :asked} = Inquiry.ask(a.id, choice())
      assert {:ok, _, :asked} = Inquiry.ask(b.id, choice())
    end

    test "an INHERITED answer does not spend the budget — it cost nobody's attention" do
      GiTF.Config.Provider.put([:inquiries], %{max_per_mission: 1})

      m =
        mission!(%{
          answered_inquiries: [
            %{
              "mission_id" => "msn-parent",
              "phase" => "design",
              "key" => "layout",
              "answer" => "grid",
              "answer_label" => "Grid",
              "answered_by" => "operator"
            }
          ]
        })

      assert {:ok, _, :already_answered} = Inquiry.ask(m.id, choice())
      # The budget is untouched, so a genuinely new question still fits.
      assert Inquiry.budget_remaining(m.id) == 1
      assert {:ok, _, :asked} = Inquiry.ask(m.id, choice(%{key: "palette"}))
    end
  end

  describe "answering" do
    setup do
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      %{mission: m, inquiry: inquiry}
    end

    test "a choice is answered by option id", %{inquiry: inquiry} do
      assert {:ok, answered, :answered} =
               Inquiry.answer(inquiry.id, "list", answered_by: "operator")

      assert answered.status == "answered"
      assert answered.answer == "list"
      assert answered.answer_label == "List"
      assert answered.answered_by == "operator"
    end

    test "an option LABEL also resolves, and is stored as the id", %{inquiry: inquiry} do
      assert {:ok, answered, :answered} = Inquiry.answer(inquiry.id, "Grid")
      assert answered.answer == "grid"
    end

    test "an unknown option is refused and names the valid ids", %{inquiry: inquiry} do
      assert {:error, {:invalid, reason}} = Inquiry.answer(inquiry.id, "carousel")
      assert reason =~ "grid"
      assert reason =~ "list"
      assert Inquiry.status(inquiry.id) == :open
    end

    test "answering the same way twice is idempotent", %{inquiry: inquiry} do
      {:ok, first, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "a")

      assert {:ok, second, :already_answered} =
               Inquiry.answer(inquiry.id, "grid", answered_by: "b")

      assert second.answer == first.answer
      assert second.answered_by == "a"
    end

    test "a CONFLICTING second answer returns the standing one, it does not error", %{
      inquiry: inquiry
    } do
      # Work has already been re-dispatched against the first answer. An
      # opaque {:error, :invalid_transition} would tell the second caller
      # nothing about what to do next; the standing decision tells them
      # the question was already settled and how.
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "first")

      assert {:ok, standing, :already_answered} =
               Inquiry.answer(inquiry.id, "list", answered_by: "second")

      assert standing.answer == "grid"
      assert standing.answered_by == "first"
    end

    test "an unknown id is not found", _ do
      assert {:error, :not_found} = Inquiry.answer("inq-nope", "grid")
    end
  end

  describe "answering by kind" do
    test ":confirm takes booleans and their string forms" do
      m = mission!()

      {:ok, q, :asked} =
        Inquiry.ask(m.id, %{key: "k", phase: "design", kind: :confirm, prompt: "?"})

      assert {:ok, answered, :answered} = Inquiry.answer(q.id, "yes")
      assert answered.answer == true
      assert answered.answer_label == "yes"
    end

    test ":confirm refuses anything that is not a yes or a no" do
      m = mission!()

      {:ok, q, :asked} =
        Inquiry.ask(m.id, %{key: "k", phase: "design", kind: :confirm, prompt: "?"})

      assert {:error, {:invalid, reason}} = Inquiry.answer(q.id, "maybe")
      assert reason =~ "true or false"
    end

    test ":text refuses a blank answer" do
      m = mission!()
      {:ok, q, :asked} = Inquiry.ask(m.id, %{key: "k", phase: "design", kind: :text, prompt: "?"})

      assert {:error, {:invalid, reason}} = Inquiry.answer(q.id, "   ")
      assert reason =~ "cannot be blank"
    end

    test ":text stores the trimmed answer" do
      m = mission!()
      {:ok, q, :asked} = Inquiry.ask(m.id, %{key: "k", phase: "design", kind: :text, prompt: "?"})

      assert {:ok, answered, :answered} = Inquiry.answer(q.id, "  CustomerLedger  ")
      assert answered.answer == "CustomerLedger"
    end
  end

  describe "listing" do
    test "list_open/0 spans every mission, oldest first" do
      a = mission!()
      b = mission!()
      {:ok, older, :asked} = Inquiry.ask(a.id, choice())
      {:ok, newer, :asked} = Inquiry.ask(b.id, choice())

      assert Enum.map(Inquiry.list_open(), & &1.id) == [older.id, newer.id]
    end

    test "list_open/1 narrows to one mission" do
      a = mission!()
      b = mission!()
      {:ok, mine, :asked} = Inquiry.ask(a.id, choice())
      {:ok, _theirs, :asked} = Inquiry.ask(b.id, choice())

      assert Enum.map(Inquiry.list_open(a.id), & &1.id) == [mine.id]
    end

    test "an answered question leaves the open list but stays in list/1" do
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")

      assert Inquiry.list_open(m.id) == []
      assert length(Inquiry.list(m.id)) == 1
      refute Inquiry.open?(m.id)
    end
  end

  describe "gate_state/1" do
    test "a mission at awaiting_input is HELD, without consulting the store" do
      # The phase itself is the fact. Being wrong here is what cost
      # msn-ac0539 twelve hours on the approval gate.
      assert Inquiry.gate_state(%{id: "msn-x", current_phase: "awaiting_input"}) == :held
    end

    test "a live mission that never asked is FUTURE, not skipped" do
      m = mission!()
      assert Inquiry.gate_state(Archive.get(:missions, m.id)) == :future
    end

    test "a finished mission that never asked is SKIPPED" do
      m = mission!(%{status: "completed", current_phase: "completed"})
      assert Inquiry.gate_state(Archive.get(:missions, m.id)) == :skipped
    end

    test "a mission that asked and was answered is ANSWERED, wherever it is now" do
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid")

      assert Inquiry.gate_state(Archive.get(:missions, m.id)) == :answered
    end

    test "an open question is HELD even if the phase moved on underneath it" do
      m = mission!(%{current_phase: "planning"})
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())

      assert Inquiry.gate_state(Archive.get(:missions, m.id)) == :held
    end

    test "garbage never takes the page down" do
      assert Inquiry.gate_state(nil) == :future
      assert Inquiry.gate_state(%{}) == :future
    end
  end

  describe "the prompt block" do
    test "is empty when nothing was answered — it costs nothing on most runs" do
      m = mission!()
      assert Inquiry.prompt_block(m.id) == ""
    end

    test "carries the answer as a DECISION, not a suggestion" do
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "list")

      block = Inquiry.prompt_block(m.id)

      assert block =~ "OPERATOR DECISIONS"
      assert block =~ "Which layout?"
      assert block =~ "List"
      assert block =~ "do not ask them again"
    end
  end

  describe "the invitation" do
    test "is silent by default — a phase is not invited to stop the factory" do
      m = mission!()
      assert Inquiry.invitation_block(m.id, "design") == ""
      refute Inquiry.enabled?()
    end

    test "appears once enabled, and states the remaining budget" do
      GiTF.Config.Provider.put([:inquiries], %{enabled: true, max_per_mission: 2})
      m = mission!()

      block = Inquiry.invitation_block(m.id, "design")

      assert block =~ "ASKING THE OPERATOR"
      assert block =~ "at most 2 more"
    end

    test "goes silent again once the budget is spent" do
      GiTF.Config.Provider.put([:inquiries], %{enabled: true, max_per_mission: 1})
      m = mission!()
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())

      assert Inquiry.invitation_block(m.id, "design") == ""
    end

    test "a phase that cannot ask is never invited to" do
      GiTF.Config.Provider.put([:inquiries], %{enabled: true})
      m = mission!()

      assert Inquiry.invitation_block(m.id, "sync") == ""
      assert Inquiry.invitation_block(m.id, "awaiting_input") == ""
      assert Inquiry.invitation_block(m.id, "design") != ""
    end
  end

  describe "escalation — the whole timeout policy" do
    test "a fresh question is not escalated" do
      m = mission!()
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())

      assert Inquiry.escalate_stale(m.id) == 0
    end

    test "a stale question alerts ONCE and keeps holding — it is never auto-answered" do
      GiTF.Config.Provider.put([:inquiries], %{alert_hours: 0})
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())

      # Backdate so awake_elapsed clears the (zero) threshold.
      Archive.update(:inquiries, inquiry.id, fn r ->
        Map.put(r, :asked_at, DateTime.add(DateTime.utc_now(), -7200, :second))
      end)

      assert Inquiry.escalate_stale(m.id) == 1
      # Second sweep is quiet: alerted_at is recorded, not recomputed.
      assert Inquiry.escalate_stale(m.id) == 0

      # And the question is STILL open. Nothing decided it.
      assert Inquiry.status(inquiry.id) == :open
      assert Inquiry.open?(m.id)
    end
  end

  describe "the answered register" do
    test "renders string-keyed entries safe to store on another mission" do
      m = mission!()
      {:ok, inquiry, :asked} = Inquiry.ask(m.id, choice())
      {:ok, _, :answered} = Inquiry.answer(inquiry.id, "grid", answered_by: "operator")

      assert [entry] = Inquiry.answered_register(m.id)
      assert entry["phase"] == "design"
      assert entry["key"] == "layout"
      assert entry["answer"] == "grid"
      assert entry["answered_by"] == "operator"
      assert entry["mission_id"] == m.id
    end

    test "an inherited entry credits the mission that actually answered it" do
      m =
        mission!(%{
          answered_inquiries: [
            %{
              "mission_id" => "msn-parent",
              "phase" => "design",
              "key" => "layout",
              "answer" => "grid",
              "answered_by" => "operator"
            }
          ]
        })

      {:ok, _, :already_answered} = Inquiry.ask(m.id, choice())

      assert [entry] = Inquiry.answered_register(m.id)
      assert entry["mission_id"] == "msn-parent"
    end

    test "open questions are not in it" do
      m = mission!()
      {:ok, _, :asked} = Inquiry.ask(m.id, choice())

      assert Inquiry.answered_register(m.id) == []
    end
  end
end
