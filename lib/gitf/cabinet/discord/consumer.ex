defmodule GiTF.Cabinet.Discord.Consumer do
  @moduledoc """
  Inbound: what Discord sends the Cabinet.

  Two events matter. `READY` — the gateway is up, reconcile the guild
  structure. `INTERACTION_CREATE` — someone pressed a button or picked from
  a menu: check they are allowed, acknowledge within Discord's three
  seconds (the act itself may wake a box and take a minute), run the one
  action the `custom_id` names, then rewrite the message as settled —
  buttons disabled, "answered by @matt 21:04" underneath.

  Who may act: the configured `operators` (Discord user ids), or, when
  none are configured, the guild's owner. Anyone else gets a private
  "not an operator here" and nothing happens.

  `MESSAGE_CREATE` is the M2 half: an operator mentioning the bot in a
  channel a persona owns gets an answer from
  `GiTF.Cabinet.Discord.Agent`. A direct message is treated as the Cabinet
  channel and answered by Kayabuki — a DM is already addressed to us, so no
  mention is required, and it carries no guild, so the operator allow-list
  is the only gate and the guild-owner fallback deliberately does not
  apply. Three gates before a model ever sees the
  text — the author must not be a bot (or two personas could talk each
  other in a circle), must be an operator, and must have mentioned us;
  and the channel must map to a persona. A message failing any of them is
  ignored in silence, not refused out loud: a busy channel is not a place
  to argue with people.
  """

  use Nostrum.Consumer

  require Logger

  alias GiTF.Cabinet.Discord
  alias GiTF.Cabinet.Discord.{Actions, Agent, Bot, Guild, Proposal, Render}
  alias Nostrum.Api

  # Interaction types and response types (Discord constants).
  @message_component 3
  @channel_message 4
  @deferred_update 6
  @ephemeral 64

  @impl true
  def handle_event({:READY, _data, _ws}), do: Bot.connected()

  def handle_event({:INTERACTION_CREATE, %{type: @message_component} = interaction, _ws}) do
    # Nostrum copies member.user into `user` for guild interactions.
    user = interaction.user && interaction.user.id
    username = (interaction.user && interaction.user.username) || to_string(user || "unknown")

    if operator?(user, interaction.guild_id) do
      # Ack first: Discord drops an interaction not answered in 3 s, and a
      # tap that wakes a sleeping box takes ~60.
      Api.Interaction.create_response(interaction, %{type: @deferred_update})

      custom_id = interaction.data.custom_id
      values = interaction.data.values || []
      actor = "discord:#{username}"

      outcome =
        case Actions.parse(custom_id, values) do
          {:ok, action} -> Actions.perform(action, actor)
          {:error, :unknown_action} -> {:error, "unknown action #{custom_id}"}
        end

      settle(interaction, outcome)
    else
      Logger.info("Cabinet Discord: ignored a tap from non-operator #{user}")

      Api.Interaction.create_response(interaction, %{
        type: @channel_message,
        data: %{content: "You are not an operator here.", flags: @ephemeral}
      })
    end
  end

  def handle_event({:MESSAGE_CREATE, message, _ws}) do
    if answerable?(message) do
      # Off the gateway process at once: an agent turn is seconds of model
      # time and may wake a box, and a blocked consumer stops every other
      # event in the guild.
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn -> answer(message) end)
    end

    :noop
  end

  def handle_event(_), do: :noop

  # -- Free text -------------------------------------------------------------

  defp answerable?(%{author: %{bot: true}}), do: false

  # A DM is already addressed to us — requiring a mention there would be
  # absurd — and it has no guild to gate on, so the operator list does the
  # whole job. See `dm_operator?/1`.
  defp answerable?(%{author: author, guild_id: nil} = message) do
    dm_operator?(author && author.id) and presence(message.content) != nil
  end

  defp answerable?(%{author: author, guild_id: guild_id} = message) do
    operator?(author && author.id, guild_id) and mentions_us?(message) and
      presence(message.content) != nil
  end

  defp answerable?(_), do: false

  # DMs require an EXPLICITLY configured operator. The guild-owner fallback
  # that `operator?/2` allows cannot apply here — there is no guild, so there
  # is no owner to be, and falling back to "anyone" is the whole attack. With
  # `operators` unset the bot simply does not answer DMs.
  defp dm_operator?(nil), do: false

  defp dm_operator?(user_id) do
    case Discord.operators(Discord.config() || %{}) do
      [] -> false
      ids -> to_string(user_id) in ids
    end
  end

  # Only when spoken to. Without this the bot answers every line in a
  # ministry channel, including the operator thinking out loud.
  defp mentions_us?(%{mentions: mentions}) when is_list(mentions) do
    case Nostrum.Cache.Me.get() do
      %{id: me} -> Enum.any?(mentions, &(&1.id == me))
      _ -> false
    end
  rescue
    _ -> false
  end

  defp mentions_us?(_), do: false

  defp answer(message) do
    channel_id = message.channel_id
    dm? = is_nil(message.guild_id)
    ministry = if dm?, do: nil, else: Bot.ministry_for_channel(channel_id)
    kind = if dm?, do: "dm", else: Guild.kind_for_channel(channel_id)
    username = (message.author && message.author.username) || "unknown"
    actor = "discord:#{username}"
    text = strip_mentions(message.content)

    Api.Channel.start_typing(channel_id)

    case Agent.answer(channel_id, kind, ministry, text, actor) do
      {:ok, result} ->
        # Relayed exchanges first: by the time Kayabuki's summary lands in
        # #cabinet, the conversation she is summarising is already visible
        # in the ministry's own channel.
        Enum.each(result.cross_posts, &post_exchange(&1, actor))

        proposals = park(result.proposals, ministry, actor, channel_id)
        Bot.say(channel_id, Render.agent_reply(result.persona, result.reply, proposals))

      {:error, :no_persona} ->
        :ok

      {:error, reason} ->
        Logger.warning("Cabinet Discord: agent failed in #{channel_id}: #{inspect(reason)}")

        Bot.say(channel_id, %{
          content: "I could not answer that one — the model call failed. Try again?",
          embeds: [],
          components: []
        })
    end
  rescue
    e ->
      Logger.error("Cabinet Discord: answering raised: #{Exception.message(e)}")
      apologise(message.channel_id)
  catch
    # An `exit` is NOT caught by rescue, and the agent turn runs inside
    # Task-wrapped code that can exit rather than return — a missing
    # supervisor did exactly that on the first live message after M2,
    # leaving the operator watching a typing indicator that never became a
    # message. Silence is the one outcome this must never produce: say
    # something, and leave the reason in the log.
    kind, reason ->
      Logger.error(
        "Cabinet Discord: answering #{kind}: #{inspect(reason, limit: 8, printable_limit: 500)}"
      )

      apologise(message.channel_id)
  end

  defp apologise(channel_id) do
    Bot.say(channel_id, %{
      content: "Something broke while I was working on that — it's in the log.",
      embeds: [],
      components: []
    })
  end

  # Kayabuki asked a ministry's Major something: both halves are posted in
  # that ministry's channel, so the exchange is a permanent record where it
  # belongs rather than a hidden call behind a summary.
  defp post_exchange(%{channel_id: nil}, _actor), do: :ok

  defp post_exchange(exchange, actor) do
    who = String.replace_prefix(actor, "discord:", "@")

    Bot.say(exchange.channel_id, %{
      content: nil,
      embeds: [
        %{
          author: %{name: "Kayabuki"},
          description: "Major — #{who} asks from #cabinet: #{exchange.question}"
        }
      ],
      components: []
    })

    proposals =
      park(
        exchange.proposals,
        %{slug: exchange.slug},
        actor,
        exchange.channel_id
      )

    Bot.say(
      exchange.channel_id,
      Render.agent_reply(exchange.persona, exchange.reply, proposals)
    )
  end

  # Each proposed write is parked before it is rendered, so the button
  # carries an id and the tap performs what was actually offered.
  defp park(proposals, ministry, actor, channel_id) do
    Enum.flat_map(proposals, fn %{tool: tool, args: args} ->
      case Proposal.create(%{
             tool: tool,
             args: args,
             slug: ministry && ministry[:slug],
             actor: actor,
             channel_id: channel_id
           }) do
        {:ok, proposal} -> [proposal]
        _ -> []
      end
    end)
  end

  # "<@1234> what is running" → "what is running". The mention is
  # addressing, not content, and leaving the raw id in confuses the model.
  defp strip_mentions(content) when is_binary(content) do
    content |> String.replace(~r/<@!?\d+>/, "") |> String.trim()
  end

  defp strip_mentions(_), do: ""

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # -- internals ---------------------------------------------------------------

  defp settle(interaction, outcome) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%H:%M UTC")

    line =
      case outcome do
        {:ok, text} -> "✓ #{text} · #{stamp}"
        {:error, reason} -> "✗ failed: #{describe(reason)} · #{stamp}"
      end

    message = interaction.message
    settled = Render.settled(message, line)

    case Api.Message.edit(message.channel_id, message.id, settled) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Cabinet Discord: could not settle message: #{inspect(reason)}")

        Api.Interaction.create_followup_message(interaction.token, %{
          content: line,
          flags: @ephemeral
        })
    end
  end

  defp operator?(nil, _guild_id), do: false

  defp operator?(user_id, guild_id) do
    cfg = Discord.config() || %{}

    # The guild gate comes first and is not negotiable. The application is
    # installable by anyone while "Public Bot" is on, so without this a
    # stranger could add the bot to a server they own and — through the
    # owner fallback below — be treated as this factory's operator, able to
    # wake boxes and tap proposals that spend money. The bot answers in
    # exactly one guild: the one it was configured for.
    with true <- our_guild?(cfg, guild_id) do
      case Discord.operators(cfg) do
        # No operators configured: the owner of OUR guild, and only because
        # the guild has already been checked above.
        [] -> user_id == Guild.owner_id(guild_id)
        ids -> to_string(user_id) in ids
      end
    else
      _ -> false
    end
  end

  defp our_guild?(cfg, guild_id) do
    case Discord.guild_id(cfg) do
      nil -> false
      configured -> to_string(configured) == to_string(guild_id)
    end
  end

  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 200)
end
