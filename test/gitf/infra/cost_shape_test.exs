defmodule GiTF.Infra.CostShapeTest do
  use ExUnit.Case, async: false

  alias GiTF.Infra.CostShape

  setup do
    # Point the baseline at a scratch dir so tests never touch a real one.
    tmp = Path.join(System.tmp_dir!(), "gitf_infra_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = :persistent_term.get({GiTF.Archive, :data_path}, nil)
    :persistent_term.put({GiTF.Archive, :data_path}, Path.join(tmp, "store.db"))

    on_exit(fn ->
      if prev,
        do: :persistent_term.put({GiTF.Archive, :data_path}, prev),
        else: :persistent_term.erase({GiTF.Archive, :data_path})

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  test "current/0 reports a shape and never raises off EC2" do
    shape = CostShape.current()
    assert Map.has_key?(shape, :instance_type)
    assert Map.has_key?(shape, :root_volume_gb)
    # A dev machine has no IMDS, but df still answers — either way, no crash.
    assert is_nil(shape.estimated_monthly_usd) or is_float(shape.estimated_monthly_usd)
  end

  test "first check records a baseline, second is quiet" do
    assert CostShape.baseline() == nil
    assert CostShape.check() in [:ok, :skipped]

    case CostShape.baseline() do
      nil ->
        # No IMDS and no df (unlikely) — the check correctly skipped.
        assert CostShape.check() == :skipped

      base ->
        assert Map.has_key?(base, "root_volume_gb")
        assert Map.has_key?(base, "recorded_at")
        # Unchanged shape must not alert.
        assert CostShape.check() == :ok
    end
  end

  test "a grown volume alerts with the monthly delta" do
    # The 2026-08-19 incident, replayed: 12GB → 24GB must be visible.
    {:ok, shape} = CostShape.accept_current()

    if shape.root_volume_gb do
      shrunk =
        shape
        |> Map.put(:root_volume_gb, shape.root_volume_gb - 12)
        |> Map.put(:estimated_monthly_usd, (shape.estimated_monthly_usd || 0.0) - 0.96)
        |> Map.put(:recorded_at, DateTime.utc_now() |> DateTime.to_iso8601())

      path =
        :persistent_term.get({GiTF.Archive, :data_path})
        |> Path.dirname()
        |> Path.join("infra_cost_baseline.json")

      File.write!(path, Jason.encode!(shrunk))

      assert {:changed, base, current, delta} = CostShape.check()
      assert base["root_volume_gb"] == shape.root_volume_gb - 12
      assert current.root_volume_gb == shape.root_volume_gb
      assert delta > 0
    end
  end

  test "accept_current/0 is the ACK: it silences an alerting change" do
    {:ok, _} = CostShape.accept_current()
    assert CostShape.check() in [:ok, :skipped]
  end
end
