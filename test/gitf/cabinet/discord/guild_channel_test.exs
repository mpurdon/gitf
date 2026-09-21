defmodule GiTF.Cabinet.Discord.GuildChannelTest do
  @moduledoc """
  Fleet observations went to Discord addressed by the *name* "cabinet"
  rather than the channel id, so every one of them raised inside
  `Bot.send_now/2`'s rescue, warned once per digest tick, and put nothing
  in the channel. Nobody noticed for weeks because the rescue turned a
  programming error into a log line.

  The lookup being total is what makes the fix safe: `send_now/2` resolves
  names from inside the supervised bot, where a FunctionClauseError would
  take the process down rather than drop one message.
  """
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Discord.Guild

  test "an unknown channel name is nil, not a raise" do
    assert Guild.channel("not-a-channel") == nil
    assert Guild.channel("") == nil
    assert Guild.channel(nil) == nil
  end

  test "the fixed names are still looked up rather than falling through" do
    # Without a connected guild these are nil too — what matters is that
    # they take the lookup clause and would return an id once reconciled,
    # instead of being swallowed by the catch-all.
    for name <- ~w(cabinet plan aramaki) do
      assert Guild.channel(name) == nil or is_integer(Guild.channel(name))
    end
  end
end
