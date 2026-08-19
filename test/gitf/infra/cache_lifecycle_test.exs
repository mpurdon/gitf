defmodule GiTF.Infra.CacheLifecycleTest do
  use ExUnit.Case, async: false

  alias GiTF.Infra.CacheLifecycle

  test "verify reports both caches with sizes" do
    assert {status, report} = CacheLifecycle.verify()
    assert status in [:ok, :degraded]
    assert %{npm_cache: npm, cargo_target: cargo} = report
    assert is_binary(npm.path) and is_integer(npm.bytes)
    assert is_binary(cargo.path) and is_integer(cargo.bytes)
  end

  test "gc leaves caches alone when they are under the size ceilings" do
    tiny = %{
      npm_cache: %{path: "/nonexistent-npm", bytes: 1_000, healthy: true},
      cargo_target: %{path: "/nonexistent-cargo", bytes: 1_000}
    }

    assert %{cargo_incremental_dropped: false, npm_cache_dropped: false} =
             CacheLifecycle.gc(tiny)
  end

  test "gc drops an oversized cargo incremental dir but never the whole cache" do
    tmp = Path.join(System.tmp_dir!(), "gitf_cache_#{System.unique_integer([:positive])}")
    incremental = Path.join(tmp, "debug/incremental")
    keep = Path.join(tmp, "debug/deps")
    File.mkdir_p!(incremental)
    File.mkdir_p!(keep)
    File.write!(Path.join(keep, "libfoo.rlib"), "artifact")
    on_exit(fn -> File.rm_rf!(tmp) end)

    oversized = %{
      npm_cache: %{path: "/nonexistent-npm", bytes: 1_000, healthy: true},
      # 9GB, over the 8GB ceiling
      cargo_target: %{path: tmp, bytes: 9 * 1024 * 1024 * 1024}
    }

    assert %{cargo_incremental_dropped: true} = CacheLifecycle.gc(oversized)
    refute File.dir?(incremental)
    # Compiled deps — the expensive part — survive.
    assert File.exists?(Path.join(keep, "libfoo.rlib"))
  end
end
