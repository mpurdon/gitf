defmodule GiTF.ObservabilityTest do
  use ExUnit.Case, async: false

  alias GiTF.Observability
  alias GiTF.Observability.{Metrics, Alerts, Health}
  alias GiTF.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-obs-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "Metrics.collect_metrics/0" do
    test "collects all metrics" do
      metrics = Metrics.collect_metrics()
      
      assert Map.has_key?(metrics, :system)
      assert Map.has_key?(metrics, :quests)
      assert Map.has_key?(metrics, :ghosts)
      assert Map.has_key?(metrics, :quality)
      assert Map.has_key?(metrics, :costs)
    end

    test "exports prometheus format" do
      output = Metrics.export_prometheus()
      
      assert output =~ "gitf_quests_total"
      assert output =~ "gitf_bees_active"
      assert output =~ "gitf_cost_total_usd"
    end
  end

  describe "Alerts.check_alerts/0" do
    test "returns empty list when no alerts" do
      alerts = Alerts.check_alerts()
      
      assert is_list(alerts)
    end

    test "detects stuck quests" do
      # Create old quest
      quest = %{
        id: "qst-stuck",
        status: "active",
        created_at: DateTime.add(DateTime.utc_now(), -3600),
        updated_at: DateTime.add(DateTime.utc_now(), -3600)
      }
      Store.insert(:quests, quest)
      
      alerts = Alerts.check_alerts()
      
      assert Enum.any?(alerts, fn {type, _} -> type == :quest_stuck end)
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
end
