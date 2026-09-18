defmodule GiTF.Cabinet.Discord.AuthorizationTest do
  @moduledoc """
  Who the bot will act for.

  The application is installable by anyone while "Public Bot" is on in the
  developer portal, so "which guild" is a security boundary and not a
  detail: a stranger who installs this bot into a server they own must not
  inherit the operator's authority over the fleet.
  """
  use ExUnit.Case, async: false

  alias GiTF.Cabinet.Discord

  @ours "1547247808145268869"
  @theirs "9999999999999999999"

  setup do
    previous = Application.get_env(:gitf, :discord_test_config)

    on_exit(fn ->
      Application.put_env(:gitf, :discord_test_config, previous)
      System.delete_env("GITF_DISCORD_GUILD_ID")
      System.delete_env("GITF_DISCORD_OPERATORS")
    end)

    :ok
  end

  describe "config resolution" do
    test "the guild id is read from the env var when the file omits it" do
      System.put_env("GITF_DISCORD_GUILD_ID", @ours)

      assert Discord.guild_id(Discord.config()) == String.to_integer(@ours)
    end

    test "operators come from a comma-separated env var" do
      System.put_env("GITF_DISCORD_GUILD_ID", @ours)
      System.put_env("GITF_DISCORD_OPERATORS", "111, 222 ,333")

      assert Discord.operators(Discord.config()) == ["111", "222", "333"]
    end

    test "no guild means no config at all, so the bot cannot start" do
      System.delete_env("GITF_DISCORD_GUILD_ID")

      # enabled?/0 is what decides whether the supervisor starts Nostrum.
      refute Discord.enabled?()
    end
  end

  describe "guild_id/1 parsing" do
    test "accepts a string or an integer and rejects anything else" do
      assert Discord.guild_id(%{guild_id: @ours}) == String.to_integer(@ours)
      assert Discord.guild_id(%{guild_id: 42}) == 42
      assert Discord.guild_id(%{guild_id: "not-a-number"}) == nil
      assert Discord.guild_id(%{}) == nil
    end

    test "a foreign guild id never equals ours" do
      # The comparison the consumer's gate depends on.
      ours = Discord.guild_id(%{guild_id: @ours})

      refute to_string(ours) == @theirs
    end
  end

  describe "operators/1" do
    test "ids are normalised to strings so a numeric config still matches" do
      assert Discord.operators(%{operators: [111, "222"]}) == ["111", "222"]
    end

    test "an empty list is the owner-fallback signal" do
      # Safe only because the consumer checks the guild first — see
      # GiTF.Cabinet.Discord.Consumer.operator?/2.
      assert Discord.operators(%{}) == []
      assert Discord.operators(%{operators: []}) == []
    end
  end
end
