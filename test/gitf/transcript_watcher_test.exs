defmodule GiTF.TranscriptWatcherTest do
  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.TranscriptWatcher

  @tmp_dir System.tmp_dir!()

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    {:ok, ghost} = Archive.insert(:ghosts, %{name: "watcher-test-ghost", status: "starting"})

    # Stop any existing TranscriptWatcher before starting a new one
    case TranscriptWatcher.lookup() do
      {:ok, pid} ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      :error -> :ok
    end

    # Start watcher with a fast poll interval for testing
    {:ok, pid} = TranscriptWatcher.start_link(poll_interval: 100)
    on_exit(fn -> safe_stop(pid) end)

    %{ghost: ghost, watcher_pid: pid}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  rescue
    _ -> :ok
  end

  describe "start_link/1" do
    test "starts the watcher process", %{watcher_pid: pid} do
      assert Process.alive?(pid)
    end

    test "registers in the Registry" do
      assert {:ok, _pid} = TranscriptWatcher.lookup()
    end
  end

  describe "watch/2 and unwatch/1" do
    test "adds and removes a ghost from the watch list", %{ghost: ghost} do
      path = create_transcript_file([])

      assert :ok = TranscriptWatcher.watch(ghost.id, path)
      assert :ok = TranscriptWatcher.unwatch(ghost.id)
    end
  end

  describe "polling" do
    test "detects new transcript entries and records costs", %{ghost: ghost} do
      path = create_transcript_file([])

      :ok = TranscriptWatcher.watch(ghost.id, path)

      # Write a cost entry to the transcript
      entry = %{
        "type" => "result",
        "usage" => %{
          "input_tokens" => 1000,
          "output_tokens" => 500
        },
        "model" => "claude-sonnet-4-20250514"
      }

      append_to_transcript(path, entry)

      # Wait for at least one poll cycle
      Process.sleep(250)

      costs = GiTF.Costs.for_bee(ghost.id)
      assert length(costs) >= 1
      assert hd(costs).input_tokens == 1000
    end
  end

  describe "final_parse/2" do
    test "performs a one-time full parse of a transcript", %{ghost: ghost} do
      entries = [
        %{
          "type" => "result",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
          "model" => "claude-sonnet-4-20250514"
        },
        %{
          "type" => "result",
          "usage" => %{"input_tokens" => 200, "output_tokens" => 100},
          "model" => "claude-sonnet-4-20250514"
        }
      ]

      path = create_transcript_file(entries)

      TranscriptWatcher.final_parse(ghost.id, path)

      costs = GiTF.Costs.for_bee(ghost.id)
      assert length(costs) == 2
    end

    test "handles missing file gracefully", %{ghost: ghost} do
      # Should not crash
      assert :ok = TranscriptWatcher.final_parse(ghost.id, "/nonexistent/transcript.jsonl")
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp create_transcript_file(entries) do
    name = "watcher_test_#{:erlang.unique_integer([:positive])}.jsonl"
    path = Path.join(@tmp_dir, name)

    content =
      entries
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    # Ensure trailing newline if content is non-empty
    content = if content == "", do: "", else: content <> "\n"

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp append_to_transcript(path, entry) do
    line = Jason.encode!(entry) <> "\n"
    File.write!(path, File.read!(path) <> line)
  end
end
