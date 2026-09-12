defmodule GiTF.Dashboard.Console.ParityTest do
  @moduledoc """
  The Console replaces the Cabinet Console, so it must not quietly drop things
  on the way. This holds the new LiveView against the old one, capability by
  capability, and fails if the old console grows one the new one lacks.

  Two capabilities are deliberately *not* carried over, and the test says so
  rather than staying silent:

    * `cycle_rule` — clicking an action cell to cycle wake→queue→drop. The rule
      editor supersedes it; until that lands the ruleset is read-only, which is
      a real (temporary) reduction and is asserted as such.
    * the `dropped` inbox filter — `Gate.handle` returns `{:drop, class}`
      without writing a record, so nothing anywhere sets that status. A filter
      that can never match reads as proof that nothing was dropped.
  """
  use ExUnit.Case, async: true

  @old "lib/gitf/dashboard/live/cabinet_live.ex"
  @new "lib/gitf/dashboard/live/console_live.ex"
  @pages "lib/gitf/dashboard/console/pages.ex"
  @format "lib/gitf/dashboard/console/format.ex"

  # Every event the Cabinet Console handles, and what covers it now.
  # `:structural` means the new console answers the need differently — with an
  # address or a link — rather than with an event of its own.
  @capabilities %{
    "view" => {:structural, "scope in the URL"},
    "select" => {:structural, "scope in the URL"},
    "itab" => {:structural, "the tab is part of the address"},
    "ifilter" => {:event, "filter"},
    "wake" => {:event, "wake"},
    "wake_open" => {:event, "open_factory"},
    "cancel_open" => {:event, "cancel_open"},
    "stop" => {:event, "stop"},
    "snapshot" => {:event, "snapshot"},
    "set_mode" => {:event, "set_mode"},
    "start_entry" => {:event, "start_entry"},
    "dismiss_entry" => {:event, "dismiss_entry"},
    "edit" => {:event, "edit"},
    "cancel_edit" => {:event, "cancel_edit"},
    "save_ministry" => {:event, "save_ministry"},
    "cycle_rule" =>
      {:deferred, "the rule editor supersedes it; the ruleset is read-only until then"}
  }

  defp events(file) do
    Regex.scan(~r/def handle_event\("([a-z_]+)"/, File.read!(file))
    |> Enum.map(fn [_, name] -> name end)
    |> MapSet.new()
  end

  defp sources, do: Enum.map_join([@new, @pages, @format], "\n", &File.read!/1)

  test "every event the Cabinet Console handles is accounted for" do
    unaccounted = MapSet.difference(events(@old), MapSet.new(Map.keys(@capabilities)))

    assert MapSet.size(unaccounted) == 0,
           """
           The Cabinet Console handles events this test does not know about: \
           #{inspect(MapSet.to_list(unaccounted))}.
           Add them to @capabilities with a decision — carried, structural or deferred.
           """
  end

  test "every capability marked as carried over is actually handled" do
    handled = events(@new)

    for {old, {:event, new}} <- @capabilities do
      assert MapSet.member?(handled, new),
             "#{old} was to be carried over as #{new}/3, and the Console does not handle it"
    end
  end

  test "the actions an operator can take on a ministry are all reachable" do
    src = sources()

    for action <- ~w(wake open_factory stop snapshot set_mode) do
      assert src =~ ~s(phx-click="#{action}"),
             "#{action} is handled but nothing on screen triggers it"
    end
  end

  test "the cold-start path survives, including the bookmark" do
    src = File.read!(@new)

    assert src =~ "Wake &amp; open", "wake-and-open is the path from a phone and must stay"
    assert src =~ "/wake/", "the bookmark that wakes and forwards must still be advertised"
    assert src =~ "cancel_open", "an operator must be able to stop waiting on a wake"
  end

  test "an activation can still be started or dismissed" do
    src = sources()
    assert src =~ ~s(phx-click="start_entry")

    assert src =~ ~s(phx-click="dismiss_entry"),
           "Dismiss is the operator's no; Start without it is half a decision"
  end

  test "registration is editable, secrets are shown by name, and both are labelled" do
    src = File.read!(@pages)

    for field <- ~w(name url instance_id webhook_secret_env api_key_env cost_cap_usd) do
      assert src =~ ~s(name="#{field}"), "the registry field #{field} is not editable"
    end

    assert src =~ "by name only", "the point of the design has to be visible on the page"
  end

  test "the factory is reachable from the Cabinet, by the name this codebase uses" do
    src = File.read!(@new)
    assert src =~ "Catwalk", "the link out to the factory must exist and be called the Catwalk"
    refute src =~ "Dashboard ↗", "that label was the old console's; the surface is the Catwalk"
  end

  test "every metric the fleet view showed is still computed" do
    src = File.read!(@format)

    for fun <- ~w(state_for sleeps_in version load spend_line) do
      assert src =~ "def #{fun}(", "the fleet view showed #{fun} and nothing computes it now"
    end
  end

  test "spend is compared against the cap that actually gates a wake" do
    src = File.read!(@format)

    assert src =~ ":spend_month_usd",
           "the Gate enforces the cap against month-to-date; showing anything else is the old bug"

    refute src =~ ~r/spend_line.*spend_usd/s,
           "spend_line must not reach for the lifetime total again"
  end

  test "the inbox filter that could never match is gone, and knowingly" do
    src = File.read!(@format)
    filters = Regex.scan(~r/def filter_inbox\(inbox, "([a-z]+)"\)/, src) |> Enum.map(&List.last/1)

    refute "dropped" in filters,
           "nothing writes status \"dropped\"; a filter that cannot match reads as proof of absence"

    assert "waiting" in filters and "woke" in filters
  end

  test "deferred capabilities are named, so the gap is a decision rather than an oversight" do
    deferred = for {old, {:deferred, why}} <- @capabilities, do: {old, why}

    assert deferred == [
             {"cycle_rule", "the rule editor supersedes it; the ruleset is read-only until then"}
           ]
  end
end
