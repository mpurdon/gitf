defmodule GiTF.Cabinet.RulesetTest do
  @moduledoc """
  A ruleset spends money: one rule turning `queue` into `wake` starts an EC2
  instance without asking. So the properties worth asserting are the ones that
  stop an operator being surprised — coverage, the diff, and the fact that
  editing never touches what is running.
  """
  use GiTF.StoreCase

  alias GiTF.Cabinet.{Gate, JDM, Registry, Ruleset}

  defp ministry!(attrs \\ %{}) do
    {:ok, m} =
      Registry.create(
        Map.merge(%{slug: "m-#{:erlang.unique_integer([:positive])}", name: "M"}, attrs)
      )

    m
  end

  defp default, do: Ruleset.from_jdm(JDM.default_rules())

  describe "the two representations are one thing" do
    test "the default ruleset survives a round trip through JDM" do
      rules = default()

      assert length(rules) == 6
      assert Ruleset.from_jdm(Ruleset.to_jdm(rules)) == rules
    end

    test "it reads the default ruleset the way the engine does" do
      rules = default()

      # rule 2: a bug, in normal or vacation, under the cap → wake
      assert %{class: ["bug"], mode: ["normal", "vacation"], cap: :under, action: "wake"} =
               Enum.at(rules, 1)

      # rule 1 constrains only the mode; an empty list means "any"
      assert %{class: [], mode: ["off"], cap: :any, action: "queue"} = Enum.at(rules, 0)
    end

    test "what it writes is still a document the engine will run" do
      assert JDM.supported?(Ruleset.to_jdm(default()))
    end

    test "the model and the engine agree on every combination" do
      rules = default()
      doc = Ruleset.to_jdm(rules)

      for {class, mode, cap} <- Ruleset.combinations() do
        input = %{"class" => class, "mode" => mode, "over_cap" => cap == :over}
        {action, _n} = Ruleset.decide(rules, class, mode, cap)

        assert {:ok, %{"action" => ^action}, _} = JDM.evaluate(doc, input),
               "model and engine disagree on #{class}/#{mode}/#{cap}"
      end
    end

    test "anything that is not a decision table reads as no rules, not a crash" do
      assert Ruleset.from_jdm(nil) == []
      assert Ruleset.from_jdm(%{"nodes" => []}) == []
      assert Ruleset.from_jdm("nonsense") == []
    end
  end

  describe "coverage" do
    test "the default ruleset decides everything, and only some of it wakes" do
      cov = Ruleset.coverage(default())

      assert cov.undecided == []
      assert length(cov.cells) == 30
      assert cov.tally["wake"] == 4
      assert cov.tally["drop"] == 8
      assert cov.tally["queue"] == 18
      assert cov.dead == [], "no rule in the default set is unreachable"
    end

    test "removing the catch-all leaves combinations undecided, and names them" do
      rules = default() |> Ruleset.delete(5)
      cov = Ruleset.coverage(rules)

      assert cov.undecided != []
      assert {"bug", "normal", :over} in cov.undecided
    end

    test "a catch-all moved to the top makes every rule under it unreachable" do
      rules = Ruleset.move(default(), 5, 1)
      cov = Ruleset.coverage(rules)

      assert cov.undecided == []
      assert cov.tally["wake"] == nil, "nothing can wake once everything queues"
      assert cov.dead == [3, 4, 5, 6]
      assert Ruleset.shadowers(rules, 2) == [2], "rule 3 is shadowed by rule 2"
    end
  end

  describe "diff" do
    test "an edit that changes nothing reports nothing" do
      assert Ruleset.diff(default(), default()) == []
    end

    test "it names the combinations that change and flags the ones that newly wake" do
      # let a bug wake even when over the cap
      edited = Ruleset.put(default(), 1, :cap, :any)
      diff = Ruleset.diff(default(), edited)

      assert length(diff) == 2, "two combinations: bug over-cap in normal and in vacation"
      assert Ruleset.newly_waking(diff) == 2

      change = Enum.find(diff, &(&1.mode == "normal"))
      assert change.from == "queue" and change.to == "wake"
      assert change.newly_wakes
    end

    test "a change that stops something waking is not flagged as newly waking" do
      edited = Ruleset.put(default(), 1, :action, "queue")
      diff = Ruleset.diff(default(), edited)

      assert length(diff) == 2
      assert Ruleset.newly_waking(diff) == 0
    end
  end

  describe "editing" do
    test "moving a rule is a move, not a swap" do
      rules = default()
      moved = Ruleset.move(rules, 5, 1)

      assert Enum.at(moved, 1) == Enum.at(rules, 5)
      assert Enum.at(moved, 2) == Enum.at(rules, 1), "the rules it passed keep their order"
      assert length(moved) == length(rules)
    end

    test "an out-of-range move leaves the ruleset alone" do
      rules = default()
      assert Ruleset.move(rules, 0, 99) == rules
      assert Ruleset.move(rules, -1, 0) == rules
      assert Ruleset.move(rules, 2, 2) == rules
    end

    test "toggling every value off means any, not nothing" do
      rules = Ruleset.toggle(default(), 1, :class, "bug")
      assert Enum.at(rules, 1).class == []

      cov = Ruleset.coverage(rules)

      assert cov.undecided == [],
             "a rule matching nothing would leave holes; it matches everything"
    end

    test "insert, duplicate and delete keep the list coherent" do
      rules = default()
      assert length(Ruleset.insert(rules, 0)) == 7
      assert length(Ruleset.duplicate(rules, 0)) == 7
      assert Enum.at(Ruleset.duplicate(rules, 0), 1) == Enum.at(rules, 0)
      assert length(Ruleset.delete(rules, 0)) == 5
    end
  end

  describe "published and draft" do
    test "editing never touches what the Gate is running" do
      m = ministry!()
      published_before = Ruleset.published(Registry.get(m.id))

      # a draft that would wake on everything
      reckless = [%{class: [], mode: [], cap: :any, action: "wake"}]
      {:ok, _} = Ruleset.save_draft(m.id, reckless)

      m2 = Registry.get(m.id)
      assert Ruleset.draft(m2) == reckless

      assert Ruleset.published(m2) == published_before,
             "publishing is the only thing that changes it"

      # and the Gate still decides by the published rules
      assert {"queue", _} = Ruleset.decide(Ruleset.published(m2), "feature", "normal", :under)
      assert {"queue", _prov} = Gate.decide(m2, :feature)
    end

    test "publishing promotes the draft, bumps the version and records who did it" do
      m = ministry!()
      edited = Ruleset.put(default(), 1, :action, "queue")
      {:ok, _} = Ruleset.save_draft(m.id, edited)

      assert {:ok, published} = Ruleset.publish(m.id, "matthew@purdonmoi.com")

      assert Ruleset.published(published) == edited
      assert Ruleset.draft(published) == nil
      assert published.rules_version == 2
      assert published.rules_published_by == "matthew@purdonmoi.com"
      assert %DateTime{} = published.rules_published_at
    end

    test "an incomplete draft cannot be published, and says how incomplete" do
      m = ministry!()
      {:ok, _} = Ruleset.save_draft(m.id, Ruleset.delete(default(), 5))

      assert {:error, {:undecided, n}} = Ruleset.publish(m.id, "someone")
      assert n > 0

      assert Ruleset.published(Registry.get(m.id)) == default(),
             "and it is left running what it was"
    end

    test "publishing with no draft is refused rather than republishing" do
      m = ministry!()
      assert {:error, :no_draft} = Ruleset.publish(m.id, "someone")
    end

    test "discarding leaves the published ruleset exactly as it was" do
      m = ministry!()
      {:ok, _} = Ruleset.save_draft(m.id, Ruleset.delete(default(), 0))
      {:ok, after_discard} = Ruleset.discard(m.id)

      assert Ruleset.draft(after_discard) == nil
      assert Ruleset.published(after_discard) == default()
    end

    test "an empty draft can be saved but not published" do
      m = ministry!()

      # Mid-edit is a legitimate state — you may have deleted every rule on the
      # way to writing better ones. It is publishing that must not let you
      # leave the Cabinet with nothing to decide by.
      assert {:ok, _} = Ruleset.save_draft(m.id, [])
      assert {:error, {:undecided, 30}} = Ruleset.publish(m.id, "someone")
      assert Ruleset.published(Registry.get(m.id)) == default()
    end
  end
end
