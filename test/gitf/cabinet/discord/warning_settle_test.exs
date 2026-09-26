defmodule GiTF.Cabinet.Discord.WarningSettleTest do
  @moduledoc """
  An idle-stop warning was only ever corrected by a human pressing one of
  its buttons: `Render.settled/3` had exactly one caller, the interaction
  handler. A box that slept on its own left the message saying "Sleeping
  soon" over a countdown that kept running — eleven hours later it read
  "Powers off 11 hours ago" under a live "Keep awake 4h" button, on a box
  that had been off since 4 AM.

  The countdown itself is right and deliberately live. What was missing is
  that nothing settled the message when the world, rather than a person,
  resolved it.
  """
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Discord.Render

  @ministry %{slug: "home-affairs", name: "Home Affairs", discord_channel_id: 1}

  defp warning do
    Render.render(
      %{
        type: "idle_stop_imminent",
        kind: "alert",
        severity: "high",
        data: %{
          stop_at: "2026-09-21T07:49:34Z",
          idle_since: "2026-09-21T07:19:34Z",
          minutes_left: 11
        }
      },
      @ministry
    )
  end

  test "the live warning is what the screenshot showed before it went stale" do
    embed = hd(warning().embeds)

    assert embed.title == "Sleeping soon"
    # Relative, so it reads "in 11 minutes" now and "11 hours ago" later —
    # correct both times, and the reason the stale message must be settled
    # rather than the timestamp made absolute.
    assert embed.description =~ "<t:#{DateTime.to_unix(~U[2026-09-21 07:49:34Z])}:R>"
  end

  test "a box that slept on its own no longer claims it is about to" do
    settled =
      Render.settled(warning(), "it slept",
        title: "Asleep",
        description: "Powered off on its own. Waking it takes about a minute."
      )

    embed = hd(settled.embeds)

    assert embed.title == "Asleep"
    refute embed.title =~ "soon"
    # The live countdown is gone with the body that carried it.
    refute embed.description =~ "<t:"
    refute embed.description =~ "Powers off"
    assert embed.footer.text =~ "it slept"
    # And the identity survives, so a fleet message still says which box.
    assert embed.footer.text =~ "Home Affairs"
  end

  test "every button is dead once the message is settled" do
    # The sharp end: tapping "Keep awake 4h" on an eleven-hour-old warning
    # would act on a box that has been asleep since before dawn.
    settled = Render.settled(warning(), "it slept", title: "Asleep")

    assert Enum.all?(settled.components, fn row ->
             Enum.all?(row.components, & &1.disabled)
           end)
  end

  test "state wording, not act wording, once EC2 has confirmed it" do
    # Actions.resolved/1 says "Powering off" because a tap lands ~90s
    # before the instance agrees. An observed transition is the opposite
    # case: it already happened.
    assert GiTF.Cabinet.Discord.Actions.resolved({:sleep, "ha"})[:title] == "Powering off"

    settled = Render.settled(warning(), "it slept", title: "Asleep")
    assert hd(settled.embeds).title == "Asleep"
  end

  describe "a hold placed anywhere settles the warning" do
    alias GiTF.Cabinet.Discord.Bot

    defp held(data), do: %{"type" => "idle_stop_held", "data" => data}

    test "the settled message names the expiry actually in force, live" do
      opts = Bot.held_opts(held(%{"expires_at" => "2026-09-26T09:15:30Z", "outcome" => "set"}))
      unix = DateTime.to_unix(~U[2026-09-26 09:15:30Z])

      settled = Render.settled(warning(), "held from the Catwalk by matt", opts)
      embed = hd(settled.embeds)

      assert embed.title == "Staying awake"
      # Exact, where a Discord tap alone could only say "at least".
      assert embed.description =~ "<t:#{unix}:t>"
      assert embed.description =~ "<t:#{unix}:R>"
      refute embed.description =~ "at least"
      assert embed.footer.text =~ "held from the Catwalk by matt"
    end

    test "a hold that changed nothing says a longer one was already there" do
      assert Bot.held_line(held(%{"outcome" => "kept", "reason" => "x"})) =~ "already in place"
      assert Bot.held_line(held(%{"outcome" => "set", "reason" => "from MCP"})) == "from MCP"
    end

    test "a malformed expiry still settles, it just cannot name the time" do
      assert Bot.held_opts(held(%{"expires_at" => "not a time"})) == [title: "Staying awake"]
      assert Bot.held_opts(held(%{})) == [title: "Staying awake"]
    end
  end
end
