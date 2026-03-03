defmodule Hive.Queen.StallDetectionTest do
  use ExUnit.Case, async: false

  alias Hive.Store

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "stall_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{}
  end

  describe "Waggle.send_checkpoint/2" do
    test "sends checkpoint waggle to queen" do
      {:ok, waggle} =
        Hive.Waggle.send_checkpoint("bee-abc123", %{
          phase: "coding",
          files_changed: 3,
          progress_pct: 45
        })

      assert waggle.from == "bee-abc123"
      assert waggle.to == "queen"
      assert waggle.subject == "checkpoint"

      body = Jason.decode!(waggle.body)
      assert body["phase"] == "coding"
      assert body["progress_pct"] == 45
    end
  end

  describe "Waggle.send_resource_warning/2" do
    test "sends resource warning waggle to queen" do
      {:ok, waggle} =
        Hive.Waggle.send_resource_warning("bee-def456", %{
          type: "context_tokens",
          current: 180_000,
          limit: 200_000
        })

      assert waggle.from == "bee-def456"
      assert waggle.to == "queen"
      assert waggle.subject == "resource_warning"

      body = Jason.decode!(waggle.body)
      assert body["type"] == "context_tokens"
      assert body["current"] == 180_000
    end
  end

  describe "detect_stalled_bees/1" do
    test "detects bees with no checkpoint beyond timeout" do
      # Create a working bee that was inserted 15 minutes ago
      old_time = DateTime.add(DateTime.utc_now(), -900, :second)

      {:ok, _bee} =
        Store.insert(:bees, %{
          name: "stale-bee",
          status: "working",
          job_id: nil,
          cell_path: nil,
          pid: nil,
          assigned_model: "sonnet",
          context_tokens_used: 0,
          context_tokens_limit: nil,
          context_percentage: 0.0,
          inserted_at: old_time
        })

      state = %{
        last_checkpoint: %{},
        stall_timeout: :timer.minutes(10)
      }

      # Should not raise, just logs warnings
      assert :ok == Hive.Queen.detect_stalled_bees(state)
    end

    test "does not flag bees with recent checkpoints" do
      {:ok, bee} =
        Store.insert(:bees, %{
          name: "active-bee",
          status: "working",
          job_id: nil,
          cell_path: nil,
          pid: nil,
          assigned_model: "sonnet",
          context_tokens_used: 0,
          context_tokens_limit: nil,
          context_percentage: 0.0
        })

      state = %{
        last_checkpoint: %{
          bee.id => %{at: DateTime.utc_now(), data: %{"phase" => "coding"}}
        },
        stall_timeout: :timer.minutes(10)
      }

      assert :ok == Hive.Queen.detect_stalled_bees(state)
    end
  end

  describe "TranscriptWatcher.maybe_emit_checkpoint/2" do
    test "emits checkpoint for coding-related entries" do
      entries = [
        %{content: "Using Write tool to create file"},
        %{content: "Using Edit tool to modify code"}
      ]

      assert :ok == Hive.TranscriptWatcher.maybe_emit_checkpoint("bee-test", entries)
    end

    test "does nothing for empty entries" do
      assert :ok == Hive.TranscriptWatcher.maybe_emit_checkpoint("bee-test", [])
    end

    test "emits checkpoint for test-related entries" do
      entries = [%{content: "Running test suite with assert checks"}]
      assert :ok == Hive.TranscriptWatcher.maybe_emit_checkpoint("bee-test", entries)
    end
  end
end
