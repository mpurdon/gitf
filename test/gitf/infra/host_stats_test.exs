defmodule GiTF.Infra.HostStatsTest do
  use ExUnit.Case, async: true

  alias GiTF.Infra.HostStats

  @moduletag :tmp_dir

  test "report never raises and always carries the BEAM's own footprint" do
    # /proc is Linux-only: on macOS the host sections degrade to nils, but
    # the BEAM numbers come from the VM and must always be present.
    report = HostStats.report()

    assert %{memory: mem, cpu: cpu, uptime: up, beam: beam, network: net, headroom: hr} = report

    assert is_integer(beam.total_mb) and beam.total_mb > 0
    assert is_integer(beam.process_count) and beam.process_count > 0
    assert is_integer(cpu.cores) and cpu.cores > 0

    assert is_map(mem) and is_map(up) and is_list(net)
    assert hr.status in ["ok", "tight", "degraded", "critical", "unknown"]
  end

  test "headroom escalates as memory tightens" do
    # Thresholds chosen from the real incidents: two OOM kills when a ~1GB
    # BEAM met a concurrent cargo build.
    plenty = HostStats.headroom_for(%{available_mb: 2_000, swap_used_mb: 0})
    tight = HostStats.headroom_for(%{available_mb: 600, swap_used_mb: 0})
    swapping = HostStats.headroom_for(%{available_mb: 1_500, swap_used_mb: 500})
    critical = HostStats.headroom_for(%{available_mb: 200, swap_used_mb: 0})

    assert plenty.status == "ok"
    assert tight.status == "tight"
    assert swapping.status == "degraded"
    assert critical.status == "critical"
  end

  test "headroom reports unknown rather than guessing when meminfo is unreadable" do
    assert HostStats.headroom_for(%{}).status == "unknown"
  end
end
