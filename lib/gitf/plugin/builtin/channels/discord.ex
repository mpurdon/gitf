defmodule GiTF.Plugin.Builtin.Channels.Discord do
  @moduledoc """
  Discord, from a factory's side: a RELAY, not a bot.

  A Discord bot needs a persistent gateway connection to receive anything
  back (a button tap, a reply), and a factory that sleeps to $0 cannot hold
  one — so the bot lives on the always-on Cabinet (`GiTF.Cabinet.Discord`)
  and every factory relays to it. This plugin turns each alert and mission
  lifecycle event into one signed `POST <relay_url>` carrying structured
  fields (type, severity, message, `data`); the Cabinet renders the embed
  and buttons, and a tap comes back as an ordinary MCP call with the actor
  set to `discord:<user>`.

  The signature is the ministry's existing GitHub webhook secret
  (`GITF_GITHUB_WEBHOOK_SECRET`) — the same key the Cabinet already holds
  for this ministry to verify GitHub with, so registering a ministry gives
  it a relay for free and the Cabinet learns no new secret.

  Degraded path: when the relay fails (Cabinet down, tailnet hiccup) and
  `fallback_webhook_env` names a Discord *incoming webhook* URL, the
  message is posted there directly — plain embed, no buttons, a dashboard
  link. The thing that makes idle-stop trustworthy (the sleep warning)
  must not itself depend on one more box being up.

  Config (`[plugins.channels.discord]` on a Section; `relay_url` may also
  arrive as `GITF_DISCORD_RELAY_URL` in the box's env file, where its other
  identity already lives):

      relay_url = "https://gitf-cabinet.tailcf2c46.ts.net:8443/relay/home-affairs"
      fallback_webhook_env = "DISCORD_WEBHOOK_URL"   # optional; this is the default name
      min_severity = "medium"                          # optional; alerts below are not relayed

  Nothing here reads free text, and nothing here needs a Discord token.
  """

  use GenServer

  require Logger

  @behaviour GiTF.Plugin.Channel

  @severity_order %{critical: 0, high: 1, medium: 2, low: 3}
  @mission_events [[:gitf, :mission, :created], [:gitf, :mission, :completed]]

  # -- Plugin callbacks ------------------------------------------------------

  @impl GiTF.Plugin.Channel
  def name, do: "discord"

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
  def subscriptions, do: []

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(config) do
    relay_url = get(config, :relay_url) || System.get_env("GITF_DISCORD_RELAY_URL")
    fallback_env = get(config, :fallback_webhook_env) || "DISCORD_WEBHOOK_URL"

    if blank?(relay_url) and blank?(System.get_env(fallback_env)) do
      Logger.info("Discord channel: no relay_url and no #{fallback_env} — disabled")
      {:ok, %{enabled: false}}
    else
      attach_telemetry()

      {:ok,
       %{
         enabled: true,
         relay_url: relay_url,
         fallback_env: fallback_env,
         min_severity: parse_severity(get(config, :min_severity), :medium)
       }}
    end
  end

  @impl true
  def handle_call({:send_message, _text, _opts}, _from, %{enabled: false} = state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call({:send_message, text, _opts}, _from, state) do
    {:reply, deliver(envelope("note", :note, :low, text, %{}), state), state}
  end

  @impl true
  def handle_cast({:notification, _event, _payload}, %{enabled: false} = state),
    do: {:noreply, state}

  def handle_cast({:notification, :alert, payload}, state) do
    severity = payload[:severity] || :high

    if rank(severity) <= rank(state.min_severity) do
      env = envelope("alert", payload[:type], severity, payload[:message], payload[:data] || %{})
      spawn_deliver(env, state)
    end

    {:noreply, state}
  end

  def handle_cast({:notification, event, payload}, state) when event in [:created, :completed] do
    type = String.to_atom("mission_#{event}")
    message = mission_message(event, payload)
    env = envelope("mission", type, :low, message, Map.take(payload, [:mission_id, :name]))
    spawn_deliver(env, state)
    {:noreply, state}
  end

  def handle_cast({:notification, _event, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def forward_alert(_event, _measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:notification, :alert, metadata})
  end

  @doc false
  def forward_mission(event, _measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:notification, List.last(event), metadata})
  end

  # -- The envelope ----------------------------------------------------------

  @doc """
  What one relayed event looks like on the wire. Structured on purpose:
  the Cabinet renders from `type` and `data`, never from the prose, and
  nothing a ghost or a webhook said travels in it.
  """
  def envelope(kind, type, severity, message, data) do
    %{
      kind: kind,
      type: to_string(type),
      severity: to_string(severity),
      message: message || "",
      data: data || %{},
      mission_id: data[:mission_id] || data["mission_id"],
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      version: GiTF.version(),
      url: server_url()
    }
  end

  # -- Delivery --------------------------------------------------------------

  defp spawn_deliver(env, state) do
    Task.Supervisor.start_child(GiTF.TaskSupervisor, fn -> deliver(env, state) end)
  end

  defp deliver(env, state) do
    case relay(env, state.relay_url) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Discord relay failed (#{inspect(reason)}); trying the fallback webhook")
        fallback(env, state.fallback_env)
    end
  end

  defp relay(_env, url) when url in [nil, ""], do: {:error, :no_relay_url}

  defp relay(env, url) do
    case secret() do
      nil ->
        {:error, :no_webhook_secret}

      secret ->
        body = Jason.encode!(env)

        case Req.post(
               url: url,
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"x-hub-signature-256", GiTF.Web.Signature.sign(body, secret)}
               ],
               retry: false,
               receive_timeout: 10_000
             ) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status}} -> {:error, {:status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Discord's incoming-webhook shape: {content, embeds}. No components —
  # a webhook has no bot to receive the tap.
  defp fallback(_env, env_name) when env_name in [nil, ""], do: {:error, :no_fallback}

  defp fallback(env, env_name) do
    case System.get_env(env_name) do
      url when is_binary(url) and url != "" ->
        payload = %{
          content: nil,
          embeds: [
            %{
              title: "#{env.type}",
              description: String.slice(env.message, 0, 1900),
              color: color(env.severity),
              url: env.url,
              footer: %{text: "GiTF #{env.version} · relay unavailable, sent direct"}
            }
          ]
        }

        case Req.post(url: url, json: payload, retry: false, receive_timeout: 10_000) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status}} -> {:error, {:status, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :fallback_env_unset}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Helpers ---------------------------------------------------------------

  defp attach_telemetry do
    :telemetry.attach(
      "section-discord-alerts",
      [:gitf, :alert, :raised],
      &__MODULE__.forward_alert/4,
      %{}
    )

    :telemetry.attach_many(
      "section-discord-missions",
      @mission_events,
      &__MODULE__.forward_mission/4,
      %{}
    )
  rescue
    _ -> :ok
  end

  defp mission_message(:created, p), do: "Mission #{p[:mission_id]} created: #{p[:name]}"
  defp mission_message(:completed, p), do: "Mission #{p[:mission_id]} completed: #{p[:name]}"

  defp secret do
    Application.get_env(:gitf, :github_webhook_secret) ||
      System.get_env("GITF_GITHUB_WEBHOOK_SECRET")
  end

  defp server_url do
    case GiTF.Config.server_url() do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp get(config, key), do: Map.get(config, key) || Map.get(config, to_string(key))
  defp blank?(v), do: v in [nil, ""]

  defp rank(severity), do: Map.get(@severity_order, severity, 1)

  defp parse_severity(nil, default), do: default

  defp parse_severity(s, default) do
    case to_string(s) do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> default
    end
  end

  defp color("critical"), do: 0xE5484D
  defp color("high"), do: 0xF76B15
  defp color("medium"), do: 0xFFC53D
  defp color(_), do: 0x8B8D98
end
