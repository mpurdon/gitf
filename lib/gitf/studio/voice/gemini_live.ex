defmodule GiTF.Studio.Voice.GeminiLive do
  @moduledoc """
  `GiTF.Studio.VoiceSession` adapter for the Google Gemini Live API, via
  `gemini_ex`'s `Gemini.Live.Session` (plain WebSocket, server-side VAD,
  native barge-in, tool calling mid-stream).

  This module is a thin translation layer: gemini_ex callbacks → owner-pid
  event messages, ReqLLM tools → Gemini function declarations, and PCM in /
  base64 PCM out. All conversation/tool semantics live with the caller
  (`GiTF.Web.StudioVoiceChannel` + `GiTF.Studio.Session`).
  """

  @behaviour GiTF.Studio.VoiceSession

  require Logger

  alias Gemini.Live.{Audio, Session}
  alias Gemini.Types.Live.{ServerContent, ServerMessage}

  @default_model "gemini-2.5-flash-native-audio-preview-12-2025"

  @impl true
  def start_session(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GiTF.Runtime.Keys.load()

    session_opts = [
      model: model(),
      auth: :gemini,
      generation_config: %{response_modalities: ["AUDIO"]},
      system_instruction: %{
        parts: [%{text: Keyword.get(opts, :system_prompt, "")}]
      },
      tools: declare_tools(Keyword.get(opts, :tools, [])),
      output_audio_transcription: %{},
      input_audio_transcription: %{},
      on_message: fn msg -> handle_message(owner, msg) end,
      on_tool_call: fn tool_call -> forward_tool_call(owner, tool_call) end,
      on_transcription: fn t -> forward_transcription(owner, t) end,
      on_error: fn err -> send(owner, {:voice_error, err}) end,
      on_close: fn _ -> send(owner, :voice_closed) end
    ]

    with {:ok, pid} <- Session.start_link(session_opts),
         :ok <- Session.connect(pid) do
      {:ok, pid}
    end
  end

  @impl true
  def send_audio(pid, pcm) when is_binary(pcm) do
    Session.send_realtime_input(pid, audio: Audio.create_input_blob(pcm))
  end

  @impl true
  def send_tool_result(pid, %{id: id, name: name, result: result}) do
    Session.send_tool_response(pid, [%{id: id, name: name, response: %{result: result}}])
  end

  @impl true
  def close(pid) do
    Session.close(pid)
  catch
    :exit, _ -> :ok
  end

  # -- gemini_ex callback translation -------------------------------------------

  defp handle_message(owner, %ServerMessage{} = msg) do
    if ServerMessage.interrupted?(msg) do
      send(owner, :voice_interrupted)
    end

    for pcm <- extract_audio(msg), do: send(owner, {:voice_audio, pcm})
    :ok
  end

  defp handle_message(_owner, _msg), do: :ok

  defp extract_audio(%ServerMessage{server_content: %ServerContent{model_turn: %{} = turn}}) do
    (turn[:parts] || turn["parts"] || [])
    |> Enum.flat_map(fn part ->
      case part[:inline_data] || part["inlineData"] do
        %{"data" => b64} -> [Audio.decode_output(b64)]
        %{data: b64} -> [Audio.decode_output(b64)]
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  defp extract_audio(_), do: []

  defp forward_tool_call(owner, tool_call) do
    calls = Map.get(tool_call, :function_calls) || []

    Enum.each(calls, fn call ->
      send(owner, {:voice_tool_call,
       %{
         id: call[:id] || call["id"],
         name: call[:name] || call["name"],
         arguments: call[:args] || call["args"] || %{}
       }})
    end)

    # Results are sent asynchronously via send_tool_result/2 once the studio
    # session has executed the tool.
    :ok
  end

  defp forward_transcription(owner, transcription) do
    text = transcription[:text] || transcription["text"]
    # gemini_ex delivers both input (user) and output (assistant) transcriptions;
    # tag by the :type/"type" field when present, default to assistant.
    role =
      case transcription[:type] || transcription["type"] do
        t when t in [:input, "input"] -> :user
        _ -> :assistant
      end

    if is_binary(text) and text != "" do
      send(owner, {:voice_transcript, role, text})
    end

    :ok
  end

  defp declare_tools(reqllm_tools) do
    declarations =
      Enum.map(reqllm_tools, fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          parameters: tool.parameter_schema
        }
      end)

    [%{function_declarations: declarations}]
  end

  defp model do
    Application.get_env(:gitf, :studio, [])
    |> Keyword.get(:voice_model, @default_model)
  end
end
