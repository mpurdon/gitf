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
  "not an operator here" and nothing happens. Free text is ignored in M1;
  the agent that reads it is M2 (`docs/plans/discord.md` D3).
  """

  use Nostrum.Consumer

  require Logger

  alias GiTF.Cabinet.Discord
  alias GiTF.Cabinet.Discord.{Actions, Bot, Guild, Render}
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

  def handle_event(_), do: :noop

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
    case Discord.operators(Discord.config() || %{}) do
      [] -> user_id == Guild.owner_id(guild_id)
      ids -> to_string(user_id) in ids
    end
  end

  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 200)
end
