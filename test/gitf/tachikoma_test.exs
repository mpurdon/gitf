defmodule GiTF.TachikomaTest do
  use ExUnit.Case, async: false

  alias GiTF.Tachikoma

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Ensure no tachikoma is running before each test
    case Tachikoma.lookup() do
      {:ok, pid} ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end

    :ok
  end

  describe "start_link/1" do
    test "starts the tachikoma GenServer" do
      assert {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "rejects duplicate start" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      assert {:error, {:already_started, ^pid}} = Tachikoma.start_link(poll_interval: 60_000)
      GenServer.stop(pid)
    end
  end

  describe "lookup/0" do
    test "finds running tachikoma via Registry" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      assert {:ok, ^pid} = Tachikoma.lookup()
      GenServer.stop(pid)
    end

    test "returns :error when no tachikoma is running" do
      assert :error = Tachikoma.lookup()
    end
  end

  describe "last_results/0" do
    test "returns empty list initially" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      assert Tachikoma.last_results() == []
      GenServer.stop(pid)
    end
  end

  describe "check_now/0" do
    test "triggers an immediate patrol and returns results" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      results = Tachikoma.check_now()
      assert is_list(results)
      assert length(results) > 0

      Enum.each(results, fn r ->
        assert is_atom(r.name)
        assert r.status in [:ok, :warn, :error]
      end)

      GenServer.stop(pid)
    end

    test "results are persisted in last_results" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      results = Tachikoma.check_now()
      assert Tachikoma.last_results() == results
      GenServer.stop(pid)
    end
  end

  describe "polling" do
    test "runs patrol on timer" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 100)
      # Wait for at least one patrol cycle
      Process.sleep(250)
      results = Tachikoma.last_results()
      assert is_list(results)
      assert length(results) > 0
      GenServer.stop(pid)
    end
  end

  describe "fault tolerance" do
    test "handles unexpected messages gracefully" do
      {:ok, pid} = Tachikoma.start_link(poll_interval: 60_000)
      send(pid, :unexpected_message)
      # Should still be alive
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
