defmodule GiTF.Cabinet.Discord do
  @moduledoc """
  The Cabinet's Discord bot — the operator's phone, and the reply path back
  into the fleet (`docs/plans/discord.md`).

  Only the Cabinet is always on, so only the Cabinet holds the gateway
  connection. Each ministry's factory relays its alerts here
  (`GiTF.Plugin.Builtin.Channels.Discord` → `POST /relay/:slug`); this side
  renders them into embeds with buttons in that ministry's channel, and a
  tap runs one tool on that factory as `discord:<user>`.

  The bot provisions its own structure in the guild and remembers it — a
  `GiTF` category with `#cabinet`, `#plan`, `#aramaki`, and one channel per
  registered ministry — so the only configuration is the guild id:

      [plugins.channels.discord]
      token_env = "DISCORD_BOT_TOKEN"     # name of the env var, never the token
      guild_id = "1547247808145268869"    # or GITF_DISCORD_GUILD_ID in the env file
      operators = ["123456789012345678"]  # Discord user ids allowed to act; empty = the guild owner
      category = "GiTF"                   # optional

  Nostrum is started here, on demand, rather than as an application of its
  own: a factory release must never try to log into Discord, and Nostrum's
  application refuses to start without a token.
  """

  use Supervisor

  require Logger

  @doc """
  The `[plugins.channels.discord]` table, with `GITF_DISCORD_GUILD_ID`,
  `GITF_DISCORD_OPERATORS` (comma-separated) and `GITF_DISCORD_CATEGORY`
  filling any key the file leaves out — the box's env file is where its
  other identity (api key, webhook secret) already arrives. Nil when
  neither names a guild.
  """
  def config do
    file =
      case GiTF.Config.Provider.get([:plugins, :channels, :discord]) do
        %{} = cfg -> cfg
        _ -> %{}
      end

    env =
      %{
        guild_id: System.get_env("GITF_DISCORD_GUILD_ID"),
        operators: split_env("GITF_DISCORD_OPERATORS"),
        category: System.get_env("GITF_DISCORD_CATEGORY")
      }
      |> Enum.reject(fn {_, v} -> v in [nil, "", []] end)
      |> Map.new()

    merged = Map.merge(env, file)
    if get(merged, :guild_id), do: merged, else: nil
  rescue
    _ -> nil
  end

  defp split_env(name) do
    case System.get_env(name) do
      nil -> []
      v -> v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  @doc "Whether this Cabinet has a bot to run: a guild id and a token in the named env var."
  def enabled? do
    case config() do
      nil -> false
      cfg -> is_binary(token(cfg)) and guild_id(cfg) != nil
    end
  end

  def token(cfg),
    do: cfg |> get(:token_env, "DISCORD_BOT_TOKEN") |> System.get_env() |> presence()

  def guild_id(cfg) do
    case get(cfg, :guild_id) do
      id when is_integer(id) -> id
      id when is_binary(id) -> with {n, ""} <- Integer.parse(id), do: n, else: (_ -> nil)
      _ -> nil
    end
  end

  def category_name(cfg), do: get(cfg, :category, "GiTF")

  @doc "Discord user ids allowed to press buttons. Empty means: the guild owner only."
  def operators(cfg) do
    cfg |> get(:operators, []) |> List.wrap() |> Enum.map(&to_string/1)
  end

  # -- Supervision -------------------------------------------------------------

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    cfg = config()

    case start_nostrum(cfg) do
      :ok ->
        children = [
          {GiTF.Cabinet.Discord.Bot, cfg},
          {GiTF.Cabinet.Discord.Consumer, name: GiTF.Cabinet.Discord.Consumer}
        ]

        Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)

      {:error, reason} ->
        Logger.error("Cabinet Discord: bot not started (#{inspect(reason)})")
        :ignore
    end
  end

  # Nostrum reads its token and intents from app env at start. Loading the
  # application (a release ships it in :load mode; under mix it is a
  # compile-time dep on the code path) and then starting it is the one
  # documented way to run it "included", and it keeps every factory build
  # free of a Discord login attempt.
  defp start_nostrum(cfg) do
    with token when is_binary(token) <- token(cfg) || {:error, :no_token},
         :ok <- load_app() do
      Application.put_env(:nostrum, :token, token)
      Application.put_env(:nostrum, :gateway_intents, [:guilds, :guild_messages])
      Application.put_env(:nostrum, :ffmpeg, nil)
      Application.put_env(:nostrum, :youtubedl, nil)
      Application.put_env(:nostrum, :streamlink, nil)
      Application.put_env(:nostrum, :num_shards, 1)

      case Application.ensure_all_started(:nostrum) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_app do
    case Application.load(:nostrum) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
      {:error, reason} -> {:error, {:load, reason}}
    end
  end

  defp get(cfg, key, default \\ nil),
    do: Map.get(cfg, key) || Map.get(cfg, to_string(key)) || default

  defp presence(""), do: nil
  defp presence(v), do: v
end
