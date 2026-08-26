defmodule GiTF.Web.StudioVoiceChannelTest do
  use ExUnit.Case, async: false

  import Mox
  import Phoenix.ChannelTest

  alias GiTF.Studio.Session

  @endpoint GiTF.Web.Endpoint

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule StubAdapter do
    @behaviour GiTF.Studio.VoiceSession

    # Reports lifecycle + mic audio to the test process; the test drives
    # provider events by messaging the owner (the channel pid) directly.
    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})

    @impl true
    def start_session(opts) do
      send(test_pid(), {:adapter_started, Keyword.fetch!(opts, :owner)})
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    @impl true
    def send_audio(_pid, pcm) do
      send(test_pid(), {:mic_audio, pcm})
      :ok
    end

    @impl true
    def send_tool_result(_pid, result) do
      send(test_pid(), {:tool_result, result})
      :ok
    end

    @impl true
    def close(_pid) do
      send(test_pid(), :adapter_closed)
      :ok
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_voice_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)

    endpoint_alive? = Process.whereis(GiTF.Web.Endpoint) != nil

    if !endpoint_alive? do
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    :persistent_term.put({StubAdapter, :test_pid}, self())

    original_studio = Application.get_env(:gitf, :studio, [])

    Application.put_env(
      :gitf,
      :studio,
      Keyword.merge(original_studio, voice_enabled: true, voice_adapter: StubAdapter)
    )

    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)

    stub(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _, _, _ ->
      {:ok,
       %ReqLLM.Response{
         id: "mock",
         model: "mock-model",
         usage: %{},
         context: ReqLLM.Context.new([]),
         message: %ReqLLM.Message{
           role: :assistant,
           content: [ReqLLM.Message.ContentPart.text("hi")]
         }
       }}
    end)

    on_exit(fn ->
      Application.put_env(:gitf, :studio, original_studio)
      Application.delete_env(:gitf, :llm_client)
      File.rm_rf!(tmp)
    end)

    {:ok, studio_id} = Session.start_session()

    %{studio_id: studio_id}
  end

  defp join_voice(studio_id) do
    {:ok, _, socket} =
      GiTF.Web.UserSocket
      |> socket("test", %{})
      |> subscribe_and_join(GiTF.Web.StudioVoiceChannel, "studio_voice:#{studio_id}")

    assert_receive {:adapter_started, _owner}
    assert_push("ready", %{})
    socket
  end

  test "join starts the adapter and relays mic audio to it", %{studio_id: studio_id} do
    socket = join_voice(studio_id)

    pcm = <<0, 1, 2, 3>>
    push(socket, "audio", %{"data" => Base.encode64(pcm)})
    assert_receive {:mic_audio, ^pcm}
  end

  test "provider audio, interruption, and transcripts reach the client", %{studio_id: studio_id} do
    socket = join_voice(studio_id)
    channel_pid = socket.channel_pid

    send(channel_pid, {:voice_audio, <<9, 9>>})
    expected = Base.encode64(<<9, 9>>)
    assert_push("audio", %{data: ^expected})

    send(channel_pid, :voice_interrupted)
    assert_push("interrupted", %{})

    send(channel_pid, {:voice_transcript, :user, "make it blue"})
    assert_push("transcript", %{role: "user", text: "make it blue"})

    # Transcript also lands in the studio session (one board for voice + text).
    assert Enum.any?(
             Session.get_state(studio_id).transcript,
             &(&1.role == :user and &1.text == "make it blue")
           )
  end

  test "voice tool calls run against the studio session and answer the model", %{
    studio_id: studio_id
  } do
    socket = join_voice(studio_id)

    send(
      socket.channel_pid,
      {:voice_tool_call, %{id: "tc-9", name: "add_decision", arguments: %{"text" => "Ship it"}}}
    )

    assert_receive {:tool_result, %{id: "tc-9", name: "add_decision", result: result}}
    assert result =~ "pending card"

    # The tool call created a proposal ghost card, same as text chat.
    assert [%{tool: "add_decision"}] = Session.get_state(studio_id).proposals
  end

  test "join is refused when voice is disabled", %{studio_id: studio_id} do
    studio = Application.get_env(:gitf, :studio, [])
    Application.put_env(:gitf, :studio, Keyword.put(studio, :voice_enabled, false))

    assert {:error, %{reason: "voice_disabled"}} =
             GiTF.Web.UserSocket
             |> socket("test", %{})
             |> subscribe_and_join(GiTF.Web.StudioVoiceChannel, "studio_voice:#{studio_id}")
  end

  test "join is refused for a dead session" do
    assert {:error, %{reason: "no_such_session"}} =
             GiTF.Web.UserSocket
             |> socket("test", %{})
             |> subscribe_and_join(GiTF.Web.StudioVoiceChannel, "studio_voice:std-nope")
  end
end
