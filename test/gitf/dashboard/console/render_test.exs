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

  alias GiTF.Dashboard.Console.{Format, Pages, Scope}

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

      html =
        render(:activity, %{
          scope: %Scope{level: :activity},
          activity: [],
          inbox: inbox,
          filter: "all"
        })

      assert html =~ "Start this"
      assert html =~ "Dismiss"
      assert html =~ "rule 4"
    end

    test "an empty inbox is a sentence, not a blank box" do
      html =
        render(:activity, %{
          scope: %Scope{level: :activity},
          activity: [],
          inbox: [],
          filter: "all"
        })

      assert html =~ "Nothing is waiting on you."
    end
  end

  describe "format" do
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
end
