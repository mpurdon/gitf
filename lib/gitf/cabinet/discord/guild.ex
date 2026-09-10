defmodule GiTF.Cabinet.Discord.Guild do
  @moduledoc """
  The bot's own structure in the guild, provisioned and reconciled by the
  bot rather than configured by hand. Discord nests exactly one level
  (category → channel → thread), and that one level is the authority
  split:

      CABINET              (category — what the Cabinet owns)
      ├─ #cabinet          fleet, inbox, sleep warnings for every factory
      ├─ #plan             projects
      └─ #aramaki          issue intake
      MINISTRIES           (category — one channel per factory)
      └─ #<ministry>       created on register
         └─ msn-…          one thread per mission, archived when it ends

  Channel ids are remembered (`:discord` record `"guild"`; a ministry's
  channel on its registry record as `discord_channel_id`) and reconciled
  by NAME against what the guild actually has, so a lost store or a
  hand-made channel of the right name both resolve to the same place, and
  the bot never creates a second `#cabinet`.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Cabinet.Registry
  alias Nostrum.Api

  @collection :discord
  @record_id "guild"
  @fixed_channels ~w(cabinet plan aramaki)

  # Discord channel types.
  @text 0
  @category 4
  @public_thread 11

  @doc "The remembered structure: %{cabinet_category_id, ministries_category_id, channels: %{name => id}, threads: %{mission_id => id}}."
  def state do
    Archive.get(@collection, @record_id) || %{id: @record_id, channels: %{}, threads: %{}}
  end

  @doc """
  Makes sure both categories, the fixed channels and every ministry's
  channel exist, creating what is missing. Idempotent; safe on every
  connect. `categories` is `%{cabinet: name, ministries: name}`.
  """
  def ensure_structure(guild_id, categories) do
    with {:ok, existing} <- Api.Guild.channels(guild_id) do
      cabinet_cat = ensure_category(guild_id, existing, categories.cabinet)
      ministries_cat = ensure_category(guild_id, existing, categories.ministries)

      channels =
        Map.new(@fixed_channels, fn name ->
          {name, ensure_text_channel(guild_id, existing, name, cabinet_cat)}
        end)

      remember(
        &Map.merge(&1, %{
          cabinet_category_id: cabinet_cat,
          ministries_category_id: ministries_cat,
          channels: channels
        })
      )

      for ministry <- Registry.list(), do: ensure_ministry_channel(ministry, guild_id, existing)
      :ok
    end
  end

  @doc "The channel for a ministry, creating it if needed; nil when the bot is off."
  def ensure_ministry_channel(ministry, guild_id, existing \\ nil) do
    existing = existing || channels_or_empty(guild_id)
    category_id = state()[:ministries_category_id]
    id = ensure_text_channel(guild_id, existing, ministry.slug, category_id)

    if id && ministry[:discord_channel_id] != id do
      Registry.update(ministry.id, &Map.put(&1, :discord_channel_id, id))
    end

    id
  end

  @doc "A ministry was retired: keep the transcript, mark the channel."
  def retire_ministry_channel(%{discord_channel_id: id, slug: slug}) when is_integer(id) do
    Api.Channel.modify(id, %{name: "retired-#{slug}"}, "ministry retired")
    :ok
  end

  def retire_ministry_channel(_), do: :ok

  @doc "The id of a fixed channel (\"cabinet\", \"plan\", \"aramaki\")."
  def channel(name) when name in @fixed_channels, do: get_in(state(), [:channels, name])

  @doc """
  The thread for a mission inside its ministry's channel, created on first
  use. Threads keep a busy factory from flooding the channel and give
  every mission a transcript a human can scroll.
  """
  def mission_thread(channel_id, mission_id, title) when is_integer(channel_id) do
    case get_in(state(), [:threads, mission_id]) do
      id when is_integer(id) ->
        id

      _ ->
        name = String.slice("#{mission_id} · #{title || ""}", 0, 100) |> String.trim(" · ")

        case Api.Thread.create(
               channel_id,
               %{name: name, type: @public_thread, auto_archive_duration: 1440},
               "mission #{mission_id}"
             ) do
          {:ok, %{id: id}} ->
            remember(&put_in(&1, [:threads, mission_id], id))
            id

          {:error, reason} ->
            Logger.warning("Cabinet Discord: thread for #{mission_id} failed: #{inspect(reason)}")
            nil
        end
    end
  end

  @doc "Archives a mission's thread (terminal mission) and forgets it."
  def archive_mission_thread(mission_id) do
    case get_in(state(), [:threads, mission_id]) do
      id when is_integer(id) ->
        Api.Channel.modify(id, %{archived: true}, "mission #{mission_id} ended")
        remember(&update_in(&1, [:threads], fn t -> Map.delete(t || %{}, mission_id) end))
        :ok

      _ ->
        :ok
    end
  end

  @doc "The guild's owner id — the default operator when none is configured."
  def owner_id(guild_id) do
    case Api.Guild.get(guild_id) do
      {:ok, %{owner_id: id}} -> id
      _ -> nil
    end
  end

  # -- internals ---------------------------------------------------------------

  defp ensure_category(guild_id, existing, name) do
    case find(existing, name, @category) do
      %{id: id} ->
        id

      nil ->
        case Api.Channel.create(guild_id, %{name: name, type: @category}) do
          {:ok, %{id: id}} ->
            id

          {:error, reason} ->
            Logger.warning("Cabinet Discord: category #{name} not created: #{inspect(reason)}")
            nil
        end
    end
  end

  defp ensure_text_channel(guild_id, existing, name, category_id) do
    case find(existing, name, @text) do
      %{id: id} ->
        id

      nil ->
        attrs = %{name: name, type: @text}
        attrs = if category_id, do: Map.put(attrs, :parent_id, category_id), else: attrs

        case Api.Channel.create(guild_id, attrs) do
          {:ok, %{id: id}} ->
            Logger.info("Cabinet Discord: created ##{name}")
            id

          {:error, reason} ->
            Logger.warning("Cabinet Discord: ##{name} not created: #{inspect(reason)}")
            nil
        end
    end
  end

  defp find(existing, name, type) do
    Enum.find(existing, &(&1.name == name and &1.type == type))
  end

  defp channels_or_empty(guild_id) do
    case Api.Guild.channels(guild_id) do
      {:ok, list} -> list
      _ -> []
    end
  end

  defp remember(fun) do
    current = state()
    Archive.put(@collection, fun.(current))
  end
end
