defmodule GiTF.Web.StudioVoiceChannel do
  @moduledoc """
  Audio proxy between the browser and a `GiTF.Studio.VoiceSession` adapter
  (Pattern A: browser mic → this channel → provider WebSocket → back).

  Topic: `"studio_voice:<studio_session_id>"`. Inbound `"audio"` events carry
  base64 16kHz PCM16 chunks; outbound `"audio"` events carry base64 24kHz
  PCM16 to play. `"interrupted"` tells the client to flush its playback
  queue (barge-in). Tool calls from the voice model run against the SAME
  `GiTF.Studio.Session` the text chat uses — speaking and typing build one
  board, and results return to the model so it can narrate what it did.
  """

  use Phoenix.Channel
  require Logger

  alias GiTF.Studio.{Session, Tools, VoiceSession}

  @impl true
  def join("studio_voice:" <> studio_id, _params, socket) do
    cond do
      not VoiceSession.enabled?() ->
        {:error, %{reason: "voice_disabled"}}

      not Session.alive?(studio_id) ->
        {:error, %{reason: "no_such_session"}}

      true ->
        send(self(), :start_voice)
        {:ok, assign(socket, studio_id: studio_id, voice: nil)}
    end
  end

  @impl true
  def handle_info(:start_voice, socket) do
    adapter = VoiceSession.adapter()

    case adapter.start_session(
           owner: self(),
           system_prompt: Tools.system_prompt() <> voice_addendum(),
           tools: Tools.all()
         ) do
      {:ok, voice} ->
        push(socket, "ready", %{})
        {:noreply, assign(socket, :voice, voice)}

      {:error, reason} ->
        Logger.warning("Studio voice start failed: #{inspect(reason, limit: 10)}")
        push(socket, "voice_error", %{reason: "start_failed"})
        {:stop, :normal, socket}
    end
  end

  def handle_info({:voice_audio, pcm}, socket) do
    push(socket, "audio", %{data: Base.encode64(pcm)})
    {:noreply, socket}
  end

  def handle_info({:voice_tool_call, %{id: id, name: name, arguments: args}}, socket) do
    result =
      case Session.run_tool(socket.assigns.studio_id, name, args) do
        {:ok, text} -> text
        other -> inspect(other)
      end

    VoiceSession.adapter().send_tool_result(socket.assigns.voice, %{
      id: id,
      name: name,
      result: result
    })

    {:noreply, socket}
  end

  def handle_info({:voice_transcript, role, text}, socket) do
    Session.voice_transcript(socket.assigns.studio_id, role, text)
    push(socket, "transcript", %{role: to_string(role), text: text})
    {:noreply, socket}
  end

  def handle_info(:voice_interrupted, socket) do
    push(socket, "interrupted", %{})
    {:noreply, socket}
  end

  def handle_info({:voice_error, reason}, socket) do
    Logger.warning("Studio voice error: #{inspect(reason, limit: 10)}")
    push(socket, "voice_error", %{reason: "provider_error"})
    {:noreply, socket}
  end

  def handle_info(:voice_closed, socket) do
    push(socket, "voice_error", %{reason: "closed"})
    {:stop, :normal, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("audio", %{"data" => b64}, socket) do
    with {:ok, pcm} <- Base.decode64(b64),
         %{voice: voice} when voice != nil <- socket.assigns do
      VoiceSession.adapter().send_audio(voice, pcm)
    end

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if voice = socket.assigns[:voice] do
      VoiceSession.adapter().close(voice)
    end

    :ok
  end

  defp voice_addendum do
    """

    ## Voice-session addendum
    You are SPEAKING with the user. Keep every reply to one or two short
    sentences — the board carries the detail. Announce board changes briefly
    ("I've carded that decision — confirm it when you're ready"). Never read
    long lists aloud; summarize and point at the board.
    """
  end
end
