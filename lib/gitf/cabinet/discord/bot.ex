defmodule GiTF.Cabinet.Discord.Bot do
  @moduledoc """
  Outbound: everything the Cabinet says in Discord.

  Two sources feed it. Ministries relay their alerts and mission events
  through `POST /relay/:slug` (`post/2`); the Cabinet's own life — fleet
  transitions, queued inbox entries, operator acts — arrives over PubSub
  from `GiTF.Cabinet.Activity` and `GiTF.Cabinet.Gate`.

  Where things go:

    * a ministry's event → that ministry's channel; a mission's lifecycle
      (started / completed / failed) into the mission's thread, the thread
      created on `mission_created` and archived when the mission ends;
    * urgent alerts (questions, approvals, failures, sleep warnings) → the
      ministry channel itself, immediately — a thread is easy to miss and
      these are the reason the bot exists;
    * the sleep warning → also `#cabinet`, so one place shows every box
      about to go;
    * fleet transitions and inbox entries → `#cabinet`.

  Urgent posts go at once; the rest are batched into a digest every
  `@digest_ms`, as the Telegram channel does, so a run-13-style failure
  cascade cannot post forty embeds in a minute.
  """

  use GenServer

  require Logger

  alias GiTF.Cabinet.Discord
  alias GiTF.Cabinet.Discord.{Guild, Render}
  alias GiTF.Cabinet.Registry
  alias Nostrum.Api

  @digest_ms :timer.seconds(30)
  @digest_max 10

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  @doc "A relayed event from a ministry's factory (already verified)."
  def post(%{} = ministry, %{} = event), do: GenServer.cast(__MODULE__, {:relay, ministry, event})

  @doc "The gateway is up: reconcile the guild structure."
  def connected, do: GenServer.cast(__MODULE__, :connected)

  @doc "A ministry was registered: give it a channel."
  def ministry_registered(ministry), do: GenServer.cast(__MODULE__, {:registered, ministry})

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(cfg) do
    Phoenix.PubSub.subscribe(GiTF.PubSub, "cabinet:activity")
    Phoenix.PubSub.subscribe(GiTF.PubSub, "cabinet:inbox")
    Process.send_after(self(), :flush, @digest_ms)

    {:ok,
     %{
       guild_id: Discord.guild_id(cfg),
       categories: Discord.categories(cfg),
       digest: %{},
       # The outstanding idle-stop warning per ministry, so the world
       # resolving it can settle the message a human never touched.
       warnings: %{},
       ready: false
     }}
  end

  @impl true
  def handle_cast(:connected, state) do
    case Guild.ensure_structure(state.guild_id, state.categories) do
      :ok ->
        Logger.info("Cabinet Discord: connected to guild #{state.guild_id}, structure reconciled")

      other ->
        Logger.warning("Cabinet Discord: guild structure not reconciled: #{inspect(other)}")
    end

    {:noreply, %{state | ready: true}}
  end

  def handle_cast({:registered, ministry}, state) do
    if state.ready, do: Guild.ensure_ministry_channel(ministry, state.guild_id)
    {:noreply, state}
  end

  def handle_cast({:relay, ministry, event}, state) do
    channel_id =
      ministry[:discord_channel_id] || Guild.ensure_ministry_channel(ministry, state.guild_id)

    cond do
      is_nil(channel_id) ->
        Logger.warning(
          "Cabinet Discord: no channel for #{ministry[:slug]}; dropping #{event["type"]}"
        )

        {:noreply, state}

      event["type"] == "idle_stop_imminent" ->
        message = Render.render(event, ministry)
        slug = ministry[:slug]

        # A fresh warning makes the previous one untrue: the numbers in it
        # are stale and its buttons act on a countdown that has moved. The
        # screenshot that prompted this had two of them stacked, both live.
        state = settle_warnings(state, slug, "superseded by a later warning", [])

        posted =
          [channel_id, Guild.channel("cabinet")]
          |> Enum.uniq()
          |> Enum.flat_map(fn id ->
            case post_message(id, message) do
              {:ok, message_id} -> [%{channel_id: id, message_id: message_id, message: message}]
              :error -> []
            end
          end)

        {:noreply, put_in(state.warnings[slug], posted)}

      urgent?(event) ->
        send_now(channel_id, Render.render(event, ministry))
        {:noreply, state}

      true ->
        {:noreply, route_lifecycle(ministry, channel_id, event, state)}
    end
  end

  @impl true
  def handle_info({:cabinet_activity, %{action: "observed"} = entry}, state) do
    # The world resolved it. Until now `Render.settled/3` had exactly one
    # caller — a human pressing a button — so a box that slept on its own
    # left a message reading "Sleeping soon", counting live, still offering
    # to keep awake a box that had been off for hours.
    #
    # State wording, not act wording. `Actions.resolved/1` says "Powering
    # off" because a button tap lands ~90s before EC2 agrees; here EC2 has
    # already agreed, so the box IS asleep and the message may say so.
    state =
      case entry.result do
        "stopped" ->
          settle_warnings(state, entry.target, "it slept",
            title: "Asleep",
            description: "Powered off on its own. Waking it takes about a minute."
          )

        "running" ->
          settle_warnings(state, entry.target, "it woke",
            title: "Awake",
            description: "Powered on and accepting work."
          )

        _ ->
          state
      end

    event = %{
      "kind" => "cabinet",
      "type" => "fleet",
      "severity" => "low",
      "data" => %{"ministry" => entry.target, "state" => entry.result},
      "at" => DateTime.to_iso8601(entry.at)
    }

    {:noreply,
     digest(state, Guild.channel("cabinet"), event, %{slug: "cabinet", name: "Cabinet"})}
  end

  def handle_info({:cabinet_activity, _entry}, state), do: {:noreply, state}

  def handle_info({:inbox_queued, entry}, state) do
    event = %{
      "kind" => "cabinet",
      "type" => "inbox_queued",
      "severity" => "medium",
      "data" => %{
        "entry_id" => entry.id,
        "ministry" => entry.ministry_slug,
        "class" => entry.class,
        "summary" => entry.summary,
        "rule" => get_in(entry, [:decision, :rule])
      },
      "at" => DateTime.to_iso8601(entry.inserted_at)
    }

    send_now(Guild.channel("cabinet"), Render.render(event, %{slug: "cabinet", name: "Cabinet"}))
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    Enum.each(state.digest, fn {channel_id, items} -> flush(channel_id, Enum.reverse(items)) end)
    Process.send_after(self(), :flush, @digest_ms)
    {:noreply, %{state | digest: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Routing ---------------------------------------------------------------

  defp urgent?(event), do: event["severity"] in ["critical", "high"]

  # Mission lifecycle lives in the mission's thread: created opens it (and
  # says so in the channel by Discord's own "started a thread" line),
  # completed closes it. Anything else non-urgent joins the channel digest.
  defp route_lifecycle(ministry, channel_id, %{"type" => "mission_created"} = event, state) do
    mission_id = event["mission_id"]
    title = get_in(event, ["data", "name"])

    case Guild.mission_thread(channel_id, mission_id, title) do
      nil -> digest(state, channel_id, event, ministry)
      thread_id -> send_now(thread_id, Render.render(event, ministry)) && state
    end
  end

  defp route_lifecycle(ministry, channel_id, %{"type" => "mission_completed"} = event, state) do
    mission_id = event["mission_id"]

    case Guild.state()[:threads][mission_id] do
      thread_id when is_integer(thread_id) ->
        send_now(thread_id, Render.render(event, ministry))
        Guild.archive_mission_thread(mission_id)
        digest(state, channel_id, event, ministry)

      _ ->
        digest(state, channel_id, event, ministry)
    end
  end

  defp route_lifecycle(ministry, channel_id, event, state),
    do: digest(state, channel_id, event, ministry)

  defp digest(state, nil, _event, _ministry), do: state

  defp digest(state, channel_id, event, ministry) do
    items = [{event, ministry} | Map.get(state.digest, channel_id, [])]

    if length(items) >= @digest_max do
      flush(channel_id, Enum.reverse(items))
      %{state | digest: Map.delete(state.digest, channel_id)}
    else
      %{state | digest: Map.put(state.digest, channel_id, items)}
    end
  end

  # One message, up to ten embeds — Discord's cap per message.
  defp flush(_channel_id, []), do: :ok

  defp flush(channel_id, items) do
    embeds =
      items
      |> Enum.take(10)
      |> Enum.flat_map(fn {event, ministry} -> Render.render(event, ministry).embeds end)

    send_now(channel_id, %{content: nil, embeds: embeds, components: []})
  end

  # Settles every message still standing for `slug` and forgets them. The
  # outcome line and overrides are the same ones a button tap produces, so
  # a warning the world resolved and one a human resolved read alike.
  defp settle_warnings(state, slug, line, opts) do
    {outstanding, warnings} = Map.pop(state.warnings, slug, [])

    Enum.each(outstanding, fn %{channel_id: cid, message_id: mid, message: message} ->
      try do
        Api.Message.edit(cid, mid, Render.settled(message, line, opts))
      rescue
        e -> Logger.warning("Cabinet Discord: could not settle #{slug}: #{Exception.message(e)}")
      end
    end)

    %{state | warnings: warnings}
  end

  # `send_now/2` answers "did it go?"; this answers "where did it land?",
  # which is what a message we may need to rewrite later requires.
  defp post_message(nil, _message), do: :error

  defp post_message(channel_id, message) when is_binary(channel_id),
    do: post_message(Guild.channel(channel_id), message)

  defp post_message(channel_id, message) do
    payload = Map.reject(message, fn {_, v} -> v in [nil, []] end)

    case Api.Message.create(channel_id, payload) do
      {:ok, %{id: id}} ->
        {:ok, id}

      other ->
        Logger.warning("Cabinet Discord: post to #{channel_id} failed: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.warning("Cabinet Discord: post to #{channel_id} raised: #{Exception.message(e)}")
      :error
  end

  defp send_now(nil, _message), do: false

  # A fixed channel may be addressed by name. Every caller is supposed to
  # resolve the id first, and the one that did not — fleet observations,
  # digested under the literal string "cabinet" — raised inside the rescue
  # below on every digest tick for weeks, warned once a minute, and put
  # nothing in Discord. A name is an unambiguous thing to resolve, so
  # resolve it rather than making each caller remember.
  defp send_now(name, message) when is_binary(name) do
    case Guild.channel(name) do
      id when is_integer(id) ->
        send_now(id, message)

      _ ->
        Logger.error("Cabinet Discord: no channel id for #{inspect(name)} — message dropped")
        false
    end
  end

  defp send_now(channel_id, message) do
    payload = message |> Map.reject(fn {_, v} -> v in [nil, []] end)

    case Api.Message.create(channel_id, payload) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Cabinet Discord: send to #{channel_id} failed: #{inspect(reason)}")
        false
    end
  rescue
    e ->
      Logger.warning("Cabinet Discord: send to #{channel_id} raised: #{Exception.message(e)}")
      false
  end

  @doc """
  Posts a ready-made message (an agent's reply) to a channel.

  Goes through the same `send_now/2` as every alert, so a reply is
  rate-limited, nil-stripped and crash-guarded exactly like the rest.
  """
  @spec say(term(), map()) :: boolean()
  def say(channel_id, message), do: send_now(channel_id, message)

  @doc false
  def ministry_for_channel(channel_id) do
    Enum.find(Registry.list(), &(&1[:discord_channel_id] == channel_id))
  end
end
