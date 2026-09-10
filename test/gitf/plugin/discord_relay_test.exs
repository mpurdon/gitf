defmodule GiTF.Plugin.DiscordRelayTest do
  @moduledoc """
  A factory's Discord channel is a relay to the Cabinet: every alert
  becomes one signed POST carrying structured fields. A fake Cabinet
  stands in for the real one and verifies the signature with the same
  secret the GitHub ingress uses — the property that makes registering a
  ministry enough to give it a relay.
  """
  use ExUnit.Case, async: false

  alias GiTF.Plugin.Builtin.Channels.Discord

  @secret "relay-plugin-secret-0123456789"

  defmodule FakeCabinet do
    use Plug.Router
    plug(:match)

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason,
      body_reader: {GiTF.Web.CacheBodyReader, :read_body, []}
    )

    plug(:dispatch)

    post "/relay/:slug" do
      valid = GiTF.Web.Signature.valid?(conn, Application.get_env(:gitf, :relay_test_secret))

      send(
        Application.get_env(:gitf, :relay_test_pid),
        {:relayed, conn.path_params["slug"], valid, conn.body_params}
      )

      send_resp(conn, 200, ~s({"ok":true}))
    end

    match _ do
      send_resp(conn, 404, "{}")
    end
  end

  setup do
    port = 40_000 + :rand.uniform(20_000)
    {:ok, _} = Plug.Cowboy.http(FakeCabinet, [], port: port, ref: :"fake_cabinet_#{port}")
    Application.put_env(:gitf, :relay_test_secret, @secret)
    Application.put_env(:gitf, :relay_test_pid, self())
    prev = Application.get_env(:gitf, :github_webhook_secret)
    Application.put_env(:gitf, :github_webhook_secret, @secret)

    on_exit(fn ->
      Plug.Cowboy.shutdown(:"fake_cabinet_#{port}")
      Application.put_env(:gitf, :github_webhook_secret, prev)
      stop_existing()
    end)

    # The plugin manager boots a disabled instance (no config); replace it.
    stop_existing()

    {:ok, pid} =
      Discord.start_link(%{"relay_url" => "http://127.0.0.1:#{port}/relay/home-affairs"})

    %{pid: pid}
  end

  test "an alert with data is relayed, signed with the ministry's webhook secret", %{pid: pid} do
    Discord.send_notification(pid, :alert, %{
      type: :input_requested,
      severity: :critical,
      message: "Quest msn-1 is holding",
      data: %{mission_id: "msn-1", inquiry_id: "inq-1", kind: :choice, options: []}
    })

    assert_receive {:relayed, "home-affairs", true, body}, 5_000
    assert body["kind"] == "alert"
    assert body["type"] == "input_requested"
    assert body["severity"] == "critical"
    assert body["mission_id"] == "msn-1"
    assert body["data"]["inquiry_id"] == "inq-1"
    assert body["version"] == GiTF.version()
  end

  test "alerts below the minimum severity stay home", %{pid: pid} do
    Discord.send_notification(pid, :alert, %{
      type: :quest_completed,
      severity: :low,
      message: "done"
    })

    refute_receive {:relayed, _, _, _}, 500
  end

  test "mission lifecycle relays as its own kind", %{pid: pid} do
    Discord.send_notification(pid, :created, %{mission_id: "msn-2", name: "dark mode"})

    assert_receive {:relayed, _, true,
                    %{"kind" => "mission", "type" => "mission_created", "mission_id" => "msn-2"}},
                   5_000
  end

  test "without a relay_url or fallback the channel starts disabled" do
    stop_existing()
    {:ok, pid} = Discord.start_link(%{})
    assert {:error, :disabled} = Discord.send_message(pid, "hi")
  end

  defp stop_existing do
    case Process.whereis(Discord) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end
end
