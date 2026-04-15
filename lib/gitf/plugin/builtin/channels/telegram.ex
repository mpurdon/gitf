defmodule GiTF.Plugin.Builtin.Channels.Telegram do
  @moduledoc """
  Telegram bot messaging channel.

  Uses Telegram Bot API via `Req` (already a dep). Supports:
  - Long-polling for inbound messages
  - Formatted section event notifications (markdown)
  - Inbound command parsing (/ghost list, /mission show 1)
  - Configurable notification scoping and batching
  """

  use GenServer

  require Logger

  @behaviour GiTF.Plugin.Channel

  @poll_interval 2_000
  @default_batch_max 10

  # -- Plugin callbacks ------------------------------------------------------

  @impl GiTF.Plugin.Channel
  def name, do: "telegram"

  @impl GiTF.Plugin.Channel
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl GiTF.Plugin.Channel
  def send_message(pid, text, opts \\ []) do
    GenServer.call(pid, {:send_message, text, opts})
  end

  @impl GiTF.Plugin.Channel
  def send_notification(pid, event, payload) do
    GenServer.cast(pid, {:notification, event, payload})
  end

  @impl GiTF.Plugin.Channel
  def subscriptions do
    ["link:major", "section:system"]
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(config) do
    token = Map.get(config, :token) || Map.get(config, "token")
    chat_id = Map.get(config, :chat_id) || Map.get(config, "chat_id")

    if is_nil(token) or is_nil(chat_id) do
      Logger.warning("Telegram channel: missing token or chat_id, starting in disabled mode")
      {:ok, %{enabled: false}}
    else
      # Subscribe to PubSub topics
      for topic <- subscriptions() do
        Phoenix.PubSub.subscribe(GiTF.PubSub, topic)
      end

      # Attach telemetry handlers
      attach_telemetry(config)

      batch_config = Map.get(config, :batch, %{})
      batch_window = Map.get(batch_config, :window_secs, 30) * 1_000
      batch_max = Map.get(batch_config, :max_count, @default_batch_max)

      schedule_poll()
      schedule_batch_flush(batch_window)

      {:ok,
       %{
         enabled: true,
         token: token,
         chat_id: to_string(chat_id),
         last_update_id: 0,
         commands_enabled: Map.get(config, :commands, true),
         notify_config: Map.get(config, :notify, %{}),
         batch: [],
         batch_window: batch_window,
         batch_max: batch_max,
         urgent_events: Map.get(batch_config, :urgent, ["quest_failed", "budget_exceeded"])
       }}
    end
  end

  @impl true
  def handle_call({:send_message, _text, _opts}, _from, %{enabled: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:send_message, text, _opts}, _from, state) do
    result = do_send(state.token, state.chat_id, text)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:notification, _event, _payload}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:notification, event, payload}, state) do
    event_str = to_string(event)

    if event_str in state.urgent_events do
      text = format_notification(event, payload)
      do_send(state.token, state.chat_id, text)
      {:noreply, state}
    else
      batch = [{event, payload, System.monotonic_time(:millisecond)} | state.batch]

      if length(batch) >= state.batch_max do
        flush_batch(state.token, state.chat_id, batch)
        {:noreply, %{state | batch: []}}
      else
        {:noreply, %{state | batch: batch}}
      end
    end
  end

  @impl true
  def handle_info(:poll, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    state = poll_updates(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:flush_batch, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:flush_batch, state) do
    if state.batch != [] do
      flush_batch(state.token, state.chat_id, state.batch)
    end

    schedule_batch_flush(state.batch_window)
    {:noreply, %{state | batch: []}}
  end

  # Handle PubSub messages
  def handle_info({:link_msg, link_msg}, state) do
    text = "Link from #{link_msg.from}: #{link_msg.subject}\n#{link_msg.body || ""}"
    GenServer.cast(self(), {:notification, :link_msg, %{text: text}})
    {:noreply, state}
  end

  def handle_info({:shutdown, :initiated}, state) do
    do_send(state.token, state.chat_id, "GiTF shutting down.")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private ---------------------------------------------------------------

  defp do_send(token, chat_id, text) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"

    case Req.post(url,
           json: %{chat_id: chat_id, text: text, parse_mode: "Markdown"},
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, resp} -> {:error, {:telegram_api, resp.status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp poll_updates(state) do
    url = "https://api.telegram.org/bot#{state.token}/getUpdates"

    case Req.get(url,
           params: [offset: state.last_update_id + 1, timeout: 1],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        state = Enum.reduce(updates, state, &handle_update/2)

        case updates do
          [] -> state
          _ -> %{state | last_update_id: List.last(updates)["update_id"]}
        end

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp handle_update(%{"message" => %{"text" => text}}, state) when is_binary(text) do
    if state.commands_enabled and String.starts_with?(text, "/") do
      handle_command(text, state)
    end

    state
  end

  defp handle_update(_update, state), do: state

  defp handle_command(text, state) do
    [cmd | args] = String.trim_leading(text, "/") |> String.split(" ", parts: 2)

    case GiTF.Plugin.Registry.lookup(:command, cmd) do
      {:ok, module} ->
        arg_str = Enum.join(args, " ")
        result = module.execute(arg_str, %{pid: self()})

        receive do
          {:command_output, output} ->
            do_send(state.token, state.chat_id, output)
        after
          5_000 ->
            case result do
              :ok -> do_send(state.token, state.chat_id, "Command executed.")
              {:error, err} -> do_send(state.token, state.chat_id, "Error: #{err}")
            end
        end

      :error ->
        do_send(state.token, state.chat_id, "Unknown command: /#{cmd}")
    end
  end

  defp format_notification(event, payload) do
    case event do
      :ghost_completed -> "Ghost #{payload[:ghost_id]} completed op #{payload[:op_id]}"
      :ghost_failed -> "Ghost #{payload[:ghost_id]} failed: #{payload[:error]}"
      :quest_completed -> "Quest #{payload[:mission_id]} completed!"
      :link_msg -> payload[:text] || "New link_msg message"
      _ -> "GiTF event: #{event} #{inspect(payload)}"
    end
  end

  defp flush_batch(_token, _chat_id, []), do: :ok

  defp flush_batch(token, chat_id, batch) do
    events = Enum.reverse(batch)

    lines =
      Enum.map(events, fn {event, payload, _ts} ->
        format_notification(event, payload)
      end)

    text = "GiTF Digest (#{length(events)} events):\n\n" <> Enum.join(lines, "\n")
    do_send(token, chat_id, text)
  end

  defp attach_telemetry(config) do
    events_config = get_in(config, [:notify, :events]) || []

    telemetry_events =
      Enum.map(events_config, fn event_name ->
        case event_name do
          "job_complete" -> [:gitf, :op, :completed]
          "job_failed" -> [:gitf, :ghost, :failed]
          "quest_completed" -> [:gitf, :mission, :completed]
          "bee_crashed" -> [:gitf, :ghost, :failed]
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if telemetry_events != [] do
      :telemetry.attach_many(
        "section-telegram-channel",
        telemetry_events,
        fn event, measurements, metadata, _config ->
          event_atom = List.last(event)

          GenServer.cast(
            __MODULE__,
            {:notification, event_atom, Map.merge(measurements, metadata)}
          )
        end,
        %{}
      )
    end
  rescue
    _ -> :ok
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp schedule_batch_flush(window) do
    Process.send_after(self(), :flush_batch, window)
  end
end
