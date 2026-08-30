defmodule GiTF.MissionsAnswerInheritanceTest do
  @moduledoc """
  An answer is a decision the operator already made. A resumed run that
  re-asks it has spent their attention twice on a settled matter — and
  worse, the second answer can differ from the first, which makes the
  resumed run's provenance unreadable in exactly the way
  `contested_requirements` exists to prevent.

  So answers cross the resume boundary the way contestation does:
  `Missions.inherited_answers/1` walks the lineage and
  `create_resumed_record/3` seeds the child's `answered_inquiries` from
  it, and `GiTF.Inquiry.ask/2` consults that register BEFORE it opens
  anything.

  The identity is `{phase, key}`, never the prompt text. A ghost that
  rewords its own question between runs is asking the same question, and
  the operator should not have to notice that.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Inquiry, Missions}

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(%{name: "lineage", goal: "x", status: "failed", ops: []}, fields)
      )

    m
  end

  defp answered!(mission_id, key, answer) do
    {:ok, inquiry, :asked} =
      Inquiry.ask(mission_id, %{
        key: key,
        phase: "design",
        kind: :choice,
        prompt: "Which layout?",
        options: [%{id: "grid", label: "Grid"}, %{id: "list", label: "List"}]
      })

    {:ok, _, :answered} = Inquiry.answer(inquiry.id, answer, answered_by: "operator")
    inquiry
  end

  defp register_entry(key, answer, opts \\ []) do
    %{
      "mission_id" => Keyword.get(opts, :mission_id, "msn-ancestor"),
      "phase" => Keyword.get(opts, :phase, "design"),
      "key" => key,
      "answer" => answer,
      "answer_label" => String.capitalize(answer),
      "answered_by" => "operator"
    }
  end

  describe "inherited_answers/1" do
    test "the parent's own answered questions are inherited" do
      parent = mission!(%{})
      answered!(parent.id, "layout", "grid")

      assert [entry] = Missions.inherited_answers(Archive.get(:missions, parent.id))
      assert entry["phase"] == "design"
      assert entry["key"] == "layout"
      assert entry["answer"] == "grid"
    end

    test "a grandparent's answer survives two hops" do
      a = mission!(%{answered_inquiries: [register_entry("layout", "grid")]})
      b = mission!(%{resumed_from: a.id})

      assert [entry] = Missions.inherited_answers(b)
      assert entry["key"] == "layout"
      assert entry["mission_id"] == "msn-ancestor"
    end

    test "a later answer in the lineage outranks the one it superseded" do
      a = mission!(%{answered_inquiries: [register_entry("layout", "grid")]})
      b = mission!(%{resumed_from: a.id, answered_inquiries: [register_entry("layout", "list")]})

      assert [entry] = Missions.inherited_answers(b)
      assert entry["answer"] == "list"
    end

    test "the same key in a different phase is a different decision" do
      parent =
        mission!(%{
          answered_inquiries: [
            register_entry("name", "alpha"),
            register_entry("name", "beta", phase: "planning")
          ]
        })

      assert length(Missions.inherited_answers(parent)) == 2
    end

    test "a truncated lineage still inherits what it can reach" do
      # The ancestor record was reaped; the walk truncates rather than
      # failing, because a partial inheritance still beats none.
      orphan = mission!(%{resumed_from: "msn-long-gone"})
      assert Missions.inherited_answers(orphan) == []
    end

    test "malformed register entries are dropped, not raised on" do
      parent = mission!(%{answered_inquiries: [%{"key" => "layout"}, "nonsense", nil]})
      assert Missions.inherited_answers(parent) == []
    end

    test "an unanswered question is not inherited" do
      parent = mission!(%{})

      {:ok, _, :asked} =
        Inquiry.ask(parent.id, %{key: "layout", phase: "design", kind: :text, prompt: "?"})

      assert Missions.inherited_answers(Archive.get(:missions, parent.id)) == []
    end
  end

  describe "the child does not re-ask" do
    test "a seeded register answers the question instead of opening it" do
      child =
        mission!(%{status: "active", answered_inquiries: [register_entry("layout", "grid")]})

      assert {:ok, inquiry, :already_answered} =
               Inquiry.ask(child.id, %{
                 key: "layout",
                 phase: "design",
                 kind: :choice,
                 prompt: "Which layout?",
                 options: [%{id: "grid", label: "Grid"}, %{id: "list", label: "List"}]
               })

      assert inquiry.answer == "grid"
      # And crucially: nothing is open, so nothing holds the child.
      refute Inquiry.open?(child.id)
      assert Inquiry.list_open(child.id) == []
    end

    test "a REWORDED prompt with the same key is still answered, not re-asked" do
      child =
        mission!(%{status: "active", answered_inquiries: [register_entry("layout", "grid")]})

      assert {:ok, _, :already_answered} =
               Inquiry.ask(child.id, %{
                 key: "layout",
                 phase: "design",
                 kind: :choice,
                 prompt: "Grid or list — which reads better here?",
                 options: [%{id: "grid", label: "Grid"}, %{id: "list", label: "List"}]
               })
    end

    test "the inherited answer is credited to the run that actually gave it" do
      child =
        mission!(%{status: "active", answered_inquiries: [register_entry("layout", "grid")]})

      {:ok, inquiry, :already_answered} =
        Inquiry.ask(child.id, %{
          key: "layout",
          phase: "design",
          kind: :text,
          prompt: "Which layout?"
        })

      assert inquiry.inherited_from == "msn-ancestor"
      assert inquiry.answered_by == "operator"
    end

    test "a genuinely NEW question on the child is still asked" do
      child =
        mission!(%{status: "active", answered_inquiries: [register_entry("layout", "grid")]})

      assert {:ok, _, :asked} =
               Inquiry.ask(child.id, %{
                 key: "palette",
                 phase: "design",
                 kind: :text,
                 prompt: "What colours?"
               })

      assert Inquiry.open?(child.id)
    end
  end
end
