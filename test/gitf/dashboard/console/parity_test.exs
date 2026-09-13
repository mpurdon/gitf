defmodule GiTF.Dashboard.Console.ParityTest do
  @moduledoc """
  The Console replaces the Cabinet Console, so it must not quietly drop things
  on the way. This holds the new LiveView against the old one, capability by
  capability, and fails if the old console grows one the new one lacks.

  One capability is deliberately *not* carried over, and the test says so
  rather than staying silent: the `dropped` inbox filter. `Gate.handle` returns
  `{:drop, class}` without writing a record, so nothing anywhere sets that
  status, and a filter that can never match reads as proof that nothing was
  dropped.

  `cycle_rule` — clicking a cell to cycle wake→queue→drop — is carried by the
  rule editor, which can do that and rather more besides.
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
    "ifilter" => {:event, "toggle_facet"},
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
    "cycle_rule" => {:event, "set_rule"}
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
    assert src =~ "cancel_open", "an operator must be able to stop waiting on a wake"
  end

  test "the bookmark the page advertises actually resolves" do
    alias GiTF.Dashboard.Console.Scope

    advertised = "#{Scope.root()}/wake/home-affairs"
    assert File.read!(@new) =~ "/wake/", "the cold bookmark must still be advertised"

    scope = Scope.from_params(%{"path" => ["wake", "home-affairs"]})
    assert scope.level == :wake and scope.ministry == "home-affairs"
    assert Scope.to_path(scope) == advertised

    # and the router has to serve it, or the bookmark is a promise the page cannot keep
    assert Phoenix.Router.route_info(GiTF.Web.CabinetRouter, "GET", advertised, "cabinet") !=
             :error
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

  test "nothing sends a value on the one attribute the browser overwrites" do
    # LiveView copies a clicked element's native `el.value` over the
    # phx-value-* params, and a <button> with no value attribute reports "".
    # The Catwalk shipped every inquiry answer as "" that way (e5fd106); the
    # Console must not rediscover it.
    for file <- [@pages, "lib/gitf/dashboard/console/components.ex"] do
      # Comments may name the attribute; only a live one is a bug.
      source = String.replace(File.read!(file), ~r/<%!--.*?--%>/s, "")

      refute source =~ ~r/phx-value-value\s*=/,
             "#{file}: a <button>'s own value clobbers this param — use phx-value-v"
    end
  end

  test "no filter is offered that could never match" do
    events = File.read!("lib/gitf/dashboard/console/events.ex")

    refute events =~ ~s(:sector),
           "sectors live on the factory; a sector facet here could only ever be empty"

    assert events =~ "no sector facet",
           "and the absence has to be explained, not merely left out"

    # `dropped` is the same mistake: Gate.handle writes no record for a drop.
    gate = File.read!("lib/gitf/cabinet/gate.ex")
    refute gate =~ ~s(status: "dropped")
  end

  test "the log can be filtered, searched, and the filtered view shared" do
    src = File.read!(@pages)

    assert src =~ ~s(phx-click="toggle_facet"), "facets replace the four fixed inbox filters"
    assert src =~ ~s(phx-click="set_window")
    assert src =~ ~s(phx-change="search")
    assert src =~ ~s(phx-click="save_investigation")

    live = File.read!(@new)

    assert live =~ "push_patch",
           "a filter change must be a new URL, or the view you see is not one you can send"
  end

  test "nothing is left deferred" do
    deferred = for {old, {:deferred, why}} <- @capabilities, do: {old, why}
    assert deferred == [], "still deferred: #{inspect(deferred)}"
  end

  test "the ruleset is editable, ordered by dragging, and published deliberately" do
    src = File.read!(@pages)

    assert src =~ ~s(phx-click="toggle_rule"), "a rule's conditions must be editable"

    assert src =~ ~s(phx-click="set_rule"),
           "a rule's action must be changeable — cycle_rule's job"

    assert src =~ ~s(draggable="true"), "order is the semantics of a first-hit-wins table"
    assert src =~ ~s(phx-keydown="reorder_key"), "and reordering must not require a mouse"
    assert src =~ ~s(phx-click="publish")
    assert src =~ ~s(phx-click="discard_draft")
  end

  test "nothing in the editor can write the ruleset the Gate reads" do
    src = File.read!(@new)

    refute src =~ ~r/Registry\.update\([^)]*:rules[^_]/,
           "only Ruleset.publish/2 may replace :rules"

    assert src =~ "Ruleset.save_draft", "edits go to the draft"
    assert src =~ "Ruleset.publish", "and only publishing promotes it"
  end
end
