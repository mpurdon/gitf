defmodule GiTF.InstallCacheTest do
  @moduledoc """
  msn-5f2be2 spent 5m29s on `npm ci` before validation and 5m14s more
  while a simplify op's gate installed again — for sixteen lines of CSS.
  The cache pays for a lockfile once.
  """
  use ExUnit.Case, async: false

  alias GiTF.InstallCache

  setup do
    base = Path.join(System.tmp_dir!(), "gitf_icache_#{:erlang.unique_integer([:positive])}")
    root = Path.join(base, "cache")
    File.mkdir_p!(root)
    previous = Application.get_env(:gitf, :install_cache_root)
    Application.put_env(:gitf, :install_cache_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gitf, :install_cache_root, previous),
        else: Application.delete_env(:gitf, :install_cache_root)

      File.rm_rf(base)
    end)

    %{base: base, root: root}
  end

  defp worktree!(base, name, lock, files \\ %{}) do
    wt = Path.join(base, name)
    File.mkdir_p!(wt)
    File.write!(Path.join(wt, "package-lock.json"), lock)

    Enum.each(files, fn {rel, content} ->
      path = Path.join([wt, "node_modules", rel])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    wt
  end

  test "a worktree without a lockfile is not the cache's business", %{base: base} do
    wt = Path.join(base, "plain")
    File.mkdir_p!(wt)
    assert InstallCache.key(wt) == nil
    assert InstallCache.restore(wt) == :not_applicable
    assert InstallCache.store(wt) == :not_applicable
    assert InstallCache.env(:not_applicable) == []
  end

  test "the first worktree misses, seeds the cache after success, and the next one restores", %{
    base: base
  } do
    lock = ~s({"name":"cora","lockfileVersion":3})
    first = worktree!(base, "first", lock, %{"typescript/lib/lib.es5.d.ts" => "// ts"})
    key = InstallCache.key(first)

    # Before the command ran: node_modules already there (the ghost's own install)
    assert {:present, ^key} = InstallCache.restore(first)

    assert InstallCache.env({:present, key}) == [
             {"GITF_INSTALL_KEY", key},
             {"GITF_INSTALL_RESTORED", "0"}
           ]

    # After the command passed
    assert :stored = InstallCache.store(first)
    assert :exists = InstallCache.store(first)

    second = worktree!(base, "second", lock)
    refute File.dir?(Path.join(second, "node_modules"))

    assert {:restored, ^key} = InstallCache.restore(second)

    assert File.read!(Path.join([second, "node_modules", "typescript", "lib", "lib.es5.d.ts"])) ==
             "// ts"

    assert InstallCache.env({:restored, key}) == [
             {"GITF_INSTALL_KEY", key},
             {"GITF_INSTALL_RESTORED", "1"}
           ]

    # Restoring again is idempotent — the marker says the tree is already right
    assert {:restored, ^key} = InstallCache.restore(second)
  end

  test "a different lockfile is a different key and misses", %{base: base} do
    a = worktree!(base, "a", ~s({"v":1}), %{"x.js" => "1"})
    :stored = InstallCache.store(a)

    b = worktree!(base, "b", ~s({"v":2}))
    assert {:miss, key_b} = InstallCache.restore(b)
    refute key_b == InstallCache.key(a)
    refute File.dir?(Path.join(b, "node_modules"))
  end

  test "restored trees are hardlinks, so deleting a worktree leaves the cache intact", %{
    base: base,
    root: root
  } do
    lock = ~s({"v":3})
    a = worktree!(base, "a", lock, %{"pkg/index.js" => "module.exports = 1"})
    :stored = InstallCache.store(a)
    File.rm_rf!(a)

    b = worktree!(base, "b", lock)
    assert {:restored, key} = InstallCache.restore(b)
    assert File.read!(Path.join([b, "node_modules", "pkg", "index.js"])) == "module.exports = 1"
    assert File.dir?(Path.join([root, key, "node_modules"]))
  end

  test "prune keeps the most recently restored keys", %{base: base, root: root} do
    for {v, i} <- Enum.with_index(~w(one two three four)) do
      wt = worktree!(base, "wt-#{v}", ~s({"v":"#{v}"}), %{"f.js" => v})
      :stored = InstallCache.store(wt)
      # make mtimes distinct and ordered
      File.touch!(Path.join(root, InstallCache.key(wt)), {{2026, 1, 1}, {0, i, 0}})
    end

    assert %{removed: 2, kept: 2} = InstallCache.prune(2)
    # Doomed trees are renamed `<key>.rm-N` and unlinked in the background;
    # they are no longer keys, whether or not the rm has finished.
    remaining = root |> File.ls!() |> Enum.reject(&String.contains?(&1, ".rm-"))
    assert length(remaining) == 2
    assert %{removed: 0, kept: 2} = InstallCache.prune(2)
  end
end
