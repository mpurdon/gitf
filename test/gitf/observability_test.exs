defmodule GiTF.ObservabilityTest do
  use ExUnit.Case, async: false

  alias GiTF.Observability
  alias GiTF.Observability.{Metrics, Alerts, Health}
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-obs-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "Metrics.collect_metrics/0" do
    test "collects all metrics" do
      metrics = Metrics.collect_metrics()

      assert Map.has_key?(metrics, :system)
      assert Map.has_key?(metrics, :missions)
      assert Map.has_key?(metrics, :ghosts)
      assert Map.has_key?(metrics, :quality)
      assert Map.has_key?(metrics, :costs)
    end

    test "exports prometheus format" do
      output = Metrics.export_prometheus()

      assert output =~ "gitf_missions_total"
      assert output =~ "gitf_ghosts_active"
      assert output =~ "gitf_cost_total_usd"
    end
  end

  describe "Alerts.check_alerts/0" do
    test "returns empty list when no alerts" do
      alerts = Alerts.check_alerts()

      assert is_list(alerts)
    end

    test "detects stuck missions" do
      # Create old mission
      mission = %{
        id: "msn-stuck",
        status: "active",
        created_at: DateTime.add(DateTime.utc_now(), -3600),
        updated_at: DateTime.add(DateTime.utc_now(), -3600)
      }

      Archive.insert(:missions, mission)

      alerts = Alerts.check_alerts()

      assert Enum.any?(alerts, fn {type, _} -> type == :quest_stuck end)
    end
  end

  describe "Alerts severity and dispatch" do
    test "operator-blocking and stall alerts are webhook-eligible" do
      # These must clear the default :medium webhook floor — approval
      # requests silently rating :low was exactly the wiring gap.
      assert Alerts.severity(:approval_requested) == :critical
      assert Alerts.severity(:ghost_stalled) == :high
      assert Alerts.severity(:ghost_hard_stalled) == :high
    end

    test "dispatch_webhook emits the telemetry event messaging channels consume" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-alert-#{inspect(ref)}",
        [:gitf, :alert, :raised],
        fn _event, _measurements, metadata, _ -> send(test_pid, {:alert_raised, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-alert-#{inspect(ref)}") end)

      unique_msg = "approval needed #{System.unique_integer([:positive])}"
      Alerts.dispatch_webhook(:approval_requested, unique_msg)

      assert_receive {:alert_raised, %{type: :approval_requested, severity: :critical} = meta}
      assert meta.message == unique_msg
    end
  end

  describe "Health.check/0" do
    test "returns health status" do
      health = Health.check()

      assert Map.has_key?(health, :status)
      assert Map.has_key?(health, :checks)
      assert Map.has_key?(health, :timestamp)
    end

    test "checks store availability" do
      health = Health.check()

      assert health.checks.store == :ok
    end
  end

  describe "Observability.status/0" do
    test "returns complete status" do
      status = Observability.status()

      assert Map.has_key?(status, :health)
      assert Map.has_key?(status, :metrics)
      assert Map.has_key?(status, :alerts)
    end
  end

  # Measured 2026-08-29: this process held 303MB of a 912MB BEAM. It keeps
  # nothing — `Medic.run_all/1` and `Alerts.check_alerts/0` just allocate
  # large lists once a minute, and a GenServer heap keeps its high-water
  # mark until something hands it back.
  describe "periodic check memory" do
    # One `run_checks/0` for both claims: it is the expensive call this
    # whole describe block is about, and running it twice would only widen
    # the window in which this (non-async, store-restarting) suite can
    # collide with the async ones.
    test "the check hibernates and carries nothing forward" do
      state = %{interval: 60_000}

      assert {:noreply, after_check, :hibernate} =
               Observability.handle_info(:run_checks, state)

      assert after_check == state, "no check result may be retained in the process state"
      assert Map.keys(after_check) == [:interval]
    end

    test "unknown messages are dropped without touching the state" do
      state = %{interval: 60_000}
      assert Observability.handle_info(:something_else, state) == {:noreply, state}
    end
  end
end
