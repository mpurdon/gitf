defmodule GiTF.Dashboard.Console.EventsTest do
  @moduledoc """
  The Cabinet's two records are one story, and the facets are how you read it.

  The property that earns the complexity is the counting: a facet's numbers
  must be computed with its OWN selection excluded, or they answer "what did I
  already pick" instead of "what would I get if I also picked this".
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.Console.{Events, Scope}

  @scope %Scope{level: :activity}

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp inbox do
    [
      %{
        id: "e1",
        class: "bug",
        summary: "issue #23",
        status: "forwarded",
        ministry_slug: "home-affairs",
        decision: %{action: "wake", mode: "normal", rule: 2},
        inserted_at: ago(60)
      },
      %{
        id: "e2",
        class: "feature",
        summary: "issue #19",
        status: "queued",
        ministry_slug: "home-affairs",
        decision: %{action: "queue", mode: "normal", rule: 4},
        inserted_at: ago(3600)
      },
      %{
        id: "e3",
        class: "pr_review",
        summary: "PR #24",
        status: "forward_failed",
        ministry_slug: "trajector",
        decision: %{action: "wake", mode: "normal", rule: 3},
        inserted_at: ago(86_400 * 3)
      }
    ]
  end

  defp activity do
    [
      %{
        id: "a1",
        actor: "matthew@purdonmoi.com",
        action: "wake",
        target: "home-affairs",
        result: "starting",
        at: ago(120)
      },
      %{
        id: "a2",
        actor: "cabinet",
        action: "observed",
        target: "home-affairs",
        result: "running",
        at: ago(180)
      },
      %{
        id: "a3",
        actor: "matthew@purdonmoi.com",
        action: "ruleset.publish",
        target: "home-affairs",
        result: "v2",
        at: ago(86_400 * 10)
      },
      # older than every window but "all", so the windows actually discriminate
      %{
        id: "a4",
        actor: "matthew@purdonmoi.com",
        action: "register",
        target: "home-affairs",
        result: "ok",
        at: ago(86_400 * 40)
      }
    ]
  end

  defp stream, do: Events.build(inbox(), activity(), @scope)

  test "both records become one stream, newest first, each knowing where it goes" do
    events = stream()

    assert length(events) == 7
    assert Enum.map(events, & &1.at) == Enum.sort(Enum.map(events, & &1.at), {:desc, DateTime})
    assert Enum.all?(events, &(&1.to != nil)), "every row must be followable"
  end

  test "an act is classified by what it was, and an unknown one is not filed as something it is not" do
    events =
      Events.build(
        [],
        [%{id: "x", actor: "a", action: "teleport", target: "t", result: "?", at: ago(1)}],
        @scope
      )

    assert hd(events).kind == :other
  end

  test "an activation carries the rule that decided it" do
    activation = Enum.find(stream(), &(&1.id == "e1"))
    assert activation.kind == :activation
    assert activation.detail =~ "rule 2"
    assert activation.tone == :ok
  end

  describe "needs a person" do
    test "a queued activation does, and can be dismissed" do
      assert %{act: "Start", dismissable: true} =
               Events.needs_of(%{status: "queued", class: "feature"})
    end

    test "so does a delivery that was never handed over" do
      assert %{act: "Retry"} = Events.needs_of(%{status: "forward_failed"})
    end

    test "a forwarded one is history, not a request" do
      assert Events.needs_of(%{status: "forwarded"}) == nil
    end
  end

  describe "filtering" do
    test "selecting a kind narrows to it" do
      filters = %{Events.blank() | kind: ["activation"], when: "all"}
      assert Enum.map(Events.filter(stream(), filters), & &1.kind) |> Enum.uniq() == [:activation]
    end

    test "the time window is respected and defaults to thirty days" do
      assert length(Events.filter(stream(), %{Events.blank() | when: "24h"})) == 4

      assert length(Events.filter(stream(), Events.blank())) == 6,
             "the 40-day-old registration is outside 30 days"

      assert length(Events.filter(stream(), %{Events.blank() | when: "all"})) == 7
    end

    test "search looks across the fields a person would search" do
      filters = %{Events.blank() | q: "issue #19", when: "all"}
      assert [%{target: "issue #19"}] = Events.filter(stream(), filters)
    end

    test "facets combine as AND" do
      filters = %{Events.blank() | kind: ["activation"], ministry: ["trajector"], when: "all"}
      assert [%{id: "e3"}] = Events.filter(stream(), filters)
    end
  end

  describe "facet counts" do
    test "a facet counts itself as though nothing in it were selected" do
      events = stream()
      unfiltered = Events.facet(events, %{Events.blank() | when: "all"}, :kind)

      selected =
        Events.facet(events, %{Events.blank() | kind: ["activation"], when: "all"}, :kind)

      assert unfiltered == selected,
             "picking a kind must not change the kind counts, or they stop answering 'what if I also picked this'"
    end

    test "but another facet's selection does narrow it" do
      events = stream()
      all = Events.facet(events, %{Events.blank() | when: "all"}, :kind)

      narrowed =
        Events.facet(events, %{Events.blank() | ministry: ["trajector"], when: "all"}, :kind)

      assert Enum.find(all, &(elem(&1, 0) == :activation)) |> elem(2) == 3
      assert Enum.find(narrowed, &(elem(&1, 0) == :activation)) |> elem(2) == 1
    end

    test "a value with nothing behind it is shown at zero, not hidden" do
      narrowed =
        Events.facet(stream(), %{Events.blank() | ministry: ["trajector"], when: "all"}, :kind)

      observation = Enum.find(narrowed, &(elem(&1, 0) == :observation))

      assert observation, "the option must still be listed"
      assert elem(observation, 2) == 0, "an absence has to be legible, not invisible"
    end

    test "window counts ignore the window already chosen" do
      counts = Events.window_counts(stream(), %{Events.blank() | when: "24h"})
      assert {_, _, 7} = Enum.find(counts, &(elem(&1, 0) == "all"))
    end
  end

  describe "filters as a URL" do
    test "a blank filter set contributes no query at all" do
      assert Events.to_query(Events.blank()) == ""
    end

    test "filters round-trip through a query string" do
      filters = %{
        Events.blank()
        | kind: ["activation", "policy"],
          actor: ["cabinet"],
          when: "7d",
          q: "issue"
      }

      query = Events.to_query(filters)

      parsed = query |> String.trim_leading("?") |> URI.decode_query() |> Events.from_params()
      assert parsed == filters
    end

    test "a nonsense window falls back rather than showing nothing" do
      assert Events.from_params(%{"when" => "forever"}).when == "30d"
    end

    test "the active count drives the clear-all affordance" do
      assert Events.active_count(Events.blank()) == 0
      assert Events.active_count(%{Events.blank() | kind: ["activation"], q: "x"}) == 2
    end
  end

  test "toggling a facet value adds then removes it" do
    filters = Events.blank() |> Events.toggle(:kind, :activation)
    assert filters.kind == ["activation"]
    assert Events.toggle(filters, :kind, :activation).kind == []
  end

  describe "the vocabulary matches what the Cabinet actually writes" do
    test "every recorded action has a kind, and none fall through to :other" do
      # `Activity.record(actor, "<action>", ...)` — the literal second argument
      # at every call site in lib/. A new one landing in :other is how the
      # facet ended up offering "Other" for a perfectly ordinary dismissal.
      actions =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          Regex.scan(~r/Activity\.record\(\s*[^,]+,\s*"([a-z_.]+)"/, File.read!(file))
        end)
        |> Enum.map(&List.last/1)
        |> Enum.uniq()

      assert length(actions) > 5, "the scan found nothing; the call shape must have changed"

      unmapped =
        Enum.filter(actions, fn action ->
          acts = [%{action: action, at: DateTime.utc_now(), target: "home-affairs"}]
          [event] = Events.build([], acts, %Scope{level: :activity})
          event.kind == :other
        end)

      assert unmapped == [], "unmapped actions: #{inspect(unmapped)}"
    end

    test "an act's ministry comes from the record, not from parsing its target" do
      act = %{
        action: "dismiss",
        target: "issue #100: Crash when saving priorities",
        ministry: "home-affairs",
        at: DateTime.utc_now()
      }

      [event] = Events.build([], [act], %Scope{level: :activity})

      assert event.ministry == "home-affairs"
      assert event.kind == :activation

      # And without one, no ministry — never the issue title, which is how a
      # dismissed issue appeared in the ministry facet as though it were one.
      [bare] = Events.build([], [Map.delete(act, :ministry)], %Scope{level: :activity})
      assert bare.ministry == nil
    end
  end
end
