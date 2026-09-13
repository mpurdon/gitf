defmodule GiTF.Dashboard.Console.RenderTest do
  @moduledoc """
  Renders the Console's object pages without a socket.

  These are function components over plain maps, so they can be checked
  directly — which is the point of having pushed presentation into `Pages` and
  `Format` rather than leaving it inline in a 1000-line LiveView. What is
  asserted here is mostly *copy*: that a page says the true thing about the
  state it is in, because that is what the old console kept getting wrong.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias GiTF.Dashboard.Console.{Events, Format, Pages, Scope}

  defp render(fun, assigns), do: apply(Pages, fun, [assigns]) |> rendered_to_string()

  @running %{
    id: "gtf-1",
    slug: "home-affairs",
    name: "Home Affairs",
    mode: "normal",
    instance_id: "i-05",
    url: "https://factory.example",
    webhook_secret_env: "GITF_MIN_HA_WEBHOOK_SECRET",
    api_key_env: "GITF_MIN_HA_API_KEY",
    cost_cap_usd: nil,
    spend_month_usd: 18.07,
    sectors: ["cora", "hello-factory"],
    box: %{state: "running", state_since: DateTime.utc_now()},
    live: %{
      "status" => "ok",
      "version" => "0.65.336",
      "uptime_seconds" => 2520,
      "idle" => true,
      "idle_stop_at" => DateTime.utc_now() |> DateTime.add(1620) |> DateTime.to_iso8601(),
      "active_missions" => 0,
      "active_ghosts" => 0
    },
    live_at: DateTime.utc_now()
  }

  @asleep Map.merge(@running, %{
            box: %{state: "stopped", state_since: DateTime.utc_now() |> DateTime.add(-4000)},
            live: nil,
            live_at: nil
          })

  @scope %Scope{level: :ministry, ministry: "home-affairs"}

  describe "cabinet" do
    test "an act is described the same way here as in the activity log" do
      act = %{
        action: "ruleset.discard",
        actor: "matthew@purdonmoi.com",
        target: "home-affairs",
        result: "ok",
        at: DateTime.utc_now()
      }

      cabinet =
        render(:cabinet, %{
          scope: %Scope{level: :cabinet},
          ministries: [],
          activity: [act],
          inbox: [],
          cabinet: %{host: "h", release: "v", ingress: "i"}
        })

      assert cabinet =~ "discarded a ruleset draft for"

      refute cabinet =~ "ruleset.discard",
             "the raw action name is a field name, not a sentence"
    end
  end

  describe "ministry" do
    test "configuration is presented as configuration, not as more content" do
      html = render(:ministry, %{scope: @scope, ministry: @running, inbox: []})

      assert html =~ "Sectors"
      assert html =~ "Configuration"
      assert html =~ "how this ministry behaves, independent of what it works on"
      assert html =~ "Activation ruleset"
      assert html =~ "Registration"
    end

    test "an uncapped ministry says what that means rather than printing a dash" do
      html = render(:ministry, %{scope: @scope, ministry: @running, inbox: []})
      assert html =~ "no cap — nothing gates a wake"
    end

    test "evidence explains the state instead of repeating the overview" do
      overview = render(:ministry, %{scope: @scope, ministry: @running, inbox: []})

      evidence =
        render(:ministry, %{scope: %{@scope | tab: "evidence"}, ministry: @running, inbox: []})

      refute overview == evidence
      assert evidence =~ "Why it is in this state"
      assert evidence =~ "the Cabinet last saw it"
    end

    test "a ministry with no factory says so" do
      html =
        render(:ministry, %{
          scope: @scope,
          ministry: Map.put(@running, :instance_id, nil),
          inbox: []
        })

      assert html =~ "no factory yet"
    end
  end

  describe "registration" do
    test "every field the registry accepts is editable" do
      html = render(:registration, %{scope: @scope, ministry: @running, editing: true})

      for field <- ~w(name url instance_id webhook_secret_env api_key_env cost_cap_usd) do
        assert html =~ ~s(name="#{field}"), "#{field} is not editable"
      end
    end

    test "secrets are shown as variable names, and the page says why" do
      html = render(:registration, %{scope: @scope, ministry: @running, editing: false})

      assert html =~ "GITF_MIN_HA_WEBHOOK_SECRET"
      assert html =~ "by name only"
      assert html =~ "never stores a value"
    end

    test "the slug is immutable on an existing ministry and required on a new one" do
      existing = render(:registration, %{scope: @scope, ministry: @running, editing: true})
      assert existing =~ "immutable"
      refute existing =~ ~s(name="slug")

      fresh = render(:registration, %{scope: @scope, ministry: %{slug: nil}, editing: true})
      assert fresh =~ ~s(name="slug")
    end
  end

  describe "activity" do
    defp activity_assigns(inbox, activity \\ []) do
      scope = %Scope{level: :activity}
      events = Events.build(inbox, activity, scope)
      kinds = ["activation"]

      %{
        scope: scope,
        events: events,
        visible: Events.filter(events, Events.blank()),
        needs: Enum.filter(events, &(&1.needs && to_string(&1.kind) in kinds)),
        filters: Events.blank(),
        needs_open: true,
        needs_config_open: false,
        needs_kinds: kinds
      }
    end

    test "no control lives inside the summary that a click on it would collapse" do
      # A <button> inside <summary> activates the disclosure: the "what counts?"
      # toggle closed the band instead of opening the panel, and the panel was
      # nested inside the band, so it could never have shown either way.
      html = render(:activity, activity_assigns([]))

      [_, summary] = Regex.run(~r|<summary.*?>(.*?)</summary>|s, html)

      refute summary =~ "phx-click",
             "a click here toggles the disclosure, not the handler you meant"
    end

    test "a queued activation offers both a yes and a no" do
      inbox = [
        %{
          id: "e1",
          class: "feature",
          summary: "issue #19: Add dark mode",
          status: "queued",
          ministry_slug: "home-affairs",
          decision: %{action: "queue", mode: "normal", rule: 4},
          inserted_at: DateTime.utc_now()
        }
      ]

      html = render(:activity, activity_assigns(inbox))

      assert html =~ "Start"
      assert html =~ "Dismiss"
      assert html =~ "rule 4"
      assert html =~ "1 thing needs a person"
    end

    test "\"waiting on you\" means queued — not every activation ever seen" do
      forwarded = %{
        id: "e0",
        class: "bug",
        summary: "issue #23",
        status: "forwarded",
        ministry_slug: "home-affairs",
        decision: %{action: "wake", mode: "normal", rule: 2},
        inserted_at: DateTime.utc_now()
      }

      html =
        render(:cabinet, %{
          scope: %Scope{level: :cabinet},
          ministries: [],
          activity: [],
          inbox: [forwarded],
          cabinet: %{host: "h", release: "v", ingress: "i"}
        })

      assert html =~ "Nothing is waiting on you.",
             "a forwarded activation is history, not a thing waiting on a person"

      refute html =~ "issue #23"
    end

    test "nothing waiting says so, and says what would appear there" do
      html = render(:activity, activity_assigns([]))

      assert html =~ "Nothing needs a person"
      assert html =~ "running unattended"
      assert html =~ "Queued activations and deliveries the Cabinet"
    end
  end

  describe "format" do
    test "a log spanning midnight groups by day, so a time column is not misread" do
      events = [
        %{at: ~U[2026-09-13 01:53:00Z], actor: "a", action: "wake", target: "t", result: "ok"},
        %{at: ~U[2026-09-12 04:48:00Z], actor: "b", action: "wake", target: "t", result: "ok"},
        %{at: ~U[2026-09-12 03:33:00Z], actor: "c", action: "observed", target: "t", result: "ok"}
      ]

      assert [{d1, [_]}, {d2, [x, y]}] = Format.by_day(events)
      assert d1 =~ "2026-09-13"
      assert d2 =~ "2026-09-12"
      assert x.at == ~U[2026-09-12 04:48:00Z], "within a day, newest first"
      assert y.at == ~U[2026-09-12 03:33:00Z]
    end

    test "grouping survives a record with no timestamp" do
      assert Format.by_day([%{at: nil}, %{at: ~U[2026-09-13 01:00:00Z]}]) |> length() == 1
    end

    test "a running factory reports its own uptime, an asleep one when it stopped" do
      assert Format.state_for(@running) =~ "up 42m"
      assert Format.state_for(@asleep) =~ "asleep"
      assert Format.version(@running) == "0.65.336"
      assert Format.version(@asleep) == "—"
    end

    test "a sleeping factory has no sleep countdown to show" do
      assert Format.sleeps_in(@running) =~ "sleeps in"
      assert Format.sleeps_in(@asleep) == "—"
    end

    test "spend names the month, because the cap is monthly" do
      assert Format.spend_line(@running) =~ "this month"
      assert Format.spend_line(%{}) == "no snapshot yet"

      capped = Map.put(@running, :cost_cap_usd, 40.0)
      assert Format.spend_line(capped) == "$18.07 of $40.00 this month"
      assert Format.cap_state(capped) == "under the cap"
      assert Format.cap_tone(capped) == :ok

      over = Map.put(@running, :cost_cap_usd, 10.0)
      assert Format.cap_state(over) =~ "over the cap"
      assert Format.cap_tone(over) == :crit
    end

    test "the default ruleset reads as a decision table" do
      rows = Format.rule_rows(%{})
      assert length(rows) > 0
      assert Enum.all?(rows, &(&1.action in ~w(wake queue drop)))
      assert Enum.any?(rows, &(&1.action == "wake"))
      assert Format.ruleset_summary(%{}) =~ "wake a factory"
    end

    test "a ruleset that is not a decision table degrades to nothing, not a crash" do
      assert Format.rule_rows(%{rules: %{"nodes" => []}}) == []
      assert Format.rule_rows(%{rules: "nonsense"}) == []
    end
  end

  describe "the factory's own objects" do
    @sector %{
      id: "cora",
      name: "cora",
      path: "/srv/cora",
      repo_url: "git@github.com:mpurdon/cora.git",
      github_owner: "mpurdon",
      github_repo: "cora",
      sync_strategy: "scratch-worktree",
      validation_command: "npm test",
      validation_timeout_ms: 600_000
    }

    @mission %{
      id: "msn-7683ac",
      name: "six-level-priority",
      status: "running",
      goal: "Group the PR list by author",
      sector_id: "cora",
      current_phase: "implementation",
      priority: "normal",
      effective_priority: "high",
      priority_source: "project",
      inserted_at: "2026-09-13 01:00:00Z"
    }

    @op %{
      id: "op-2",
      title: "build the grouping",
      status: "running",
      mission_id: "msn-7683ac",
      ghost_id: "gh-11",
      description: "Group by author in the list view",
      inserted_at: "2026-09-13 01:05:00Z"
    }

    @contents %{sectors: [@sector], missions: [@mission], ops: [@op]}

    # These pages derive a little from their assigns, so they are rendered the
    # way the LiveView renders them rather than called by hand.
    defp deep(level, id, object, depth \\ @contents) do
      Phoenix.LiveViewTest.render_component(Function.capture(Pages, level, 1),
        scope: %Scope{level: level, ministry: "home-affairs", id: id},
        ministry: %{slug: "home-affairs", name: "Home Affairs"},
        object: object,
        depth: depth
      )
    end

    test "a sector shows the repository, how work lands, and its missions" do
      html = deep(:sector, "cora", @sector)

      assert html =~ "/srv/cora"
      assert html =~ "mpurdon/cora"
      assert html =~ "scratch-worktree"
      assert html =~ "npm test"
      assert html =~ "six-level-priority"
      assert html =~ "/console/m/home-affairs/msn/msn-7683ac", "a mission is reachable from here"
    end

    test "a mission shows its goal, where it is, and links to its sector" do
      html = deep(:mission, "msn-7683ac", @mission)

      assert html =~ "Group the PR list by author"
      assert html =~ "implementation"
      assert html =~ "high"
      assert html =~ "via project", "an effective priority has to say where it came from"
      assert html =~ "/console/m/home-affairs/s/cora"
      assert html =~ "/console/m/home-affairs/op/op-2"
    end

    test "an op names the ghost doing it and the mission it belongs to" do
      html = deep(:op, "op-2", @op)

      assert html =~ "gh-11"
      assert html =~ "/console/m/home-affairs/msn/msn-7683ac"
    end

    test "an unplanned mission says why there are no ops" do
      html = deep(:mission, "msn-7683ac", @mission, %{sectors: [], missions: [], ops: []})
      assert html =~ "has not been planned"
    end

    test "raw is never a dead end" do
      html =
        Phoenix.LiveViewTest.render_component(&Pages.mission/1,
          scope: %Scope{level: :mission, ministry: "home-affairs", id: "msn-7683ac", tab: "raw"},
          ministry: %{slug: "home-affairs"},
          object: @mission,
          depth: @contents
        )

      assert html =~ "msn-7683ac"
      assert html =~ "as the factory serves it"
    end

    test "a cold link to a sleeping factory explains itself and offers the wake" do
      # This is the case that matters: a mission link opened from a phone at
      # midnight must not render a blank page, and must not wake the box on its
      # own — that is a minute and a bill.
      html = deep(:mission, "msn-7683ac", {:error, :asleep}, nil)

      assert html =~ "is asleep"
      assert html =~ "bills by the hour", "the cost of the answer is part of the answer"
      assert html =~ "/console/wake/home-affairs"
    end

    test "waiting, missing and broken are three different sentences" do
      assert deep(:op, "op-2", :loading, nil) =~ "Asking home-affairs"

      gone = deep(:op, "op-2", :gone)
      assert gone =~ "awake and has no op called"
      assert gone =~ "op-2"

      assert deep(:sector, "cora", {:error, {:status, 502}}, nil) =~ "HTTP 502"
    end
  end
end
