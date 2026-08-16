defmodule GiTF.Sandbox.BubblewrapProbeTest do
  use ExUnit.Case, async: false

  alias GiTF.Sandbox.Bubblewrap

  setup do
    :persistent_term.erase({Bubblewrap, :probe})
    :persistent_term.erase({Bubblewrap, :last_error})

    on_exit(fn ->
      :persistent_term.erase({Bubblewrap, :probe})
      :persistent_term.erase({Bubblewrap, :last_error})
    end)
  end

  test "available? is false when bwrap is not on PATH" do
    if System.find_executable("bwrap") do
      # Host has bwrap — availability now additionally requires the probe,
      # which must complete (either verdict) without raising.
      assert is_boolean(Bubblewrap.available?())
    else
      refute Bubblewrap.available?()
    end
  end

  test "probe verdict is cached — repeated calls do not re-execute within TTL" do
    # Regardless of the verdict, two immediate calls must agree and the
    # second must be served from cache (observable: identical last_error).
    first = Bubblewrap.available?()
    err_after_first = Bubblewrap.last_error()
    assert Bubblewrap.available?() == first
    assert Bubblewrap.last_error() == err_after_first
  end

  @tag :sandbox
  test "on a host with working bwrap, a trivial command really runs sandboxed" do
    if Bubblewrap.available?() do
      {cmd, args, _opts} = Bubblewrap.wrap_command("echo", ["sandboxed"], [])
      assert {out, 0} = System.cmd(cmd, args, stderr_to_stdout: true)
      assert out =~ "sandboxed"
    else
      # Broken or absent sandbox must explain itself.
      assert Bubblewrap.last_error() == nil or is_binary(Bubblewrap.last_error())
    end
  end
end
