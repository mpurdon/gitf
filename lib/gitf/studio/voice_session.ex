defmodule GiTF.Studio.VoiceSession do
  @moduledoc """
  Provider-agnostic contract for a bidirectional voice session backing the
  planning studio (the Nova Sonic drive-through pattern: speech in, speech
  out, tool calls mid-conversation driving the live board).

  An adapter process streams events to its `:owner` pid as messages:

    * `{:voice_audio, pcm_binary}` — 16-bit 24kHz mono PCM to play
    * `{:voice_tool_call, %{id: _, name: _, arguments: _}}` — execute against
      `GiTF.Studio.Session.run_tool/3` and answer via `send_tool_result/2`
    * `{:voice_transcript, :user | :assistant, text}`
    * `:voice_interrupted` — user barged in; flush the playback queue
    * `{:voice_error, reason}` / `:voice_closed`

  Adapters: `GiTF.Studio.Voice.GeminiLive` (default). The active adapter is
  `config :gitf, :studio` → `:voice_adapter`, letting tests substitute a stub
  and future adapters (OpenAI Realtime, Nova Sonic) slot in without touching
  the channel or UI.
  """

  @type event ::
          {:voice_audio, binary()}
          | {:voice_tool_call, %{id: String.t(), name: String.t(), arguments: map()}}
          | {:voice_transcript, :user | :assistant, String.t()}
          | :voice_interrupted
          | {:voice_error, term()}
          | :voice_closed

  @doc """
  Start a voice session. Opts: `:owner` (event receiver pid, required),
  `:system_prompt`, `:tools` (ReqLLM.Tool list — adapter converts).
  """
  @callback start_session(keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Stream a chunk of 16-bit 16kHz mono PCM microphone audio."
  @callback send_audio(pid(), binary()) :: :ok | {:error, term()}

  @doc "Answer a tool call: `{id, name, result_text}`."
  @callback send_tool_result(pid(), %{id: String.t(), name: String.t(), result: String.t()}) ::
              :ok | {:error, term()}

  @callback close(pid()) :: :ok

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:gitf, :studio, [])
    |> Keyword.get(:voice_adapter, GiTF.Studio.Voice.GeminiLive)
  end

  @doc "Whether studio voice is enabled (config `[:studio, :voice_enabled]`)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :studio, []) |> Keyword.get(:voice_enabled, false) == true
  end
end
