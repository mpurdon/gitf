defmodule GiTF.SafeAtomTest do
  use ExUnit.Case, async: false

  alias GiTF.SafeAtom

  test "returns existing atoms without minting" do
    _ = :already_exists_probe_atom
    assert {:ok, :already_exists_probe_atom} = SafeAtom.intern("already_exists_probe_atom")
  end

  test "passes atoms through unchanged" do
    assert {:ok, :foo} = SafeAtom.intern(:foo)
  end

  test "mints a new identifier-shaped atom under the cap" do
    unique = "sa_dyn_#{System.unique_integer([:positive])}"
    assert {:ok, atom} = SafeAtom.intern(unique)
    assert Atom.to_string(atom) == unique
  end

  test "refuses non-identifier / oversized strings" do
    assert :error = SafeAtom.intern("has spaces and !!!")
    assert :error = SafeAtom.intern(String.duplicate("a", 200))
    assert :error = SafeAtom.intern("1starts_with_digit")
  end

  test "intern!/2 falls back to a sentinel atom" do
    assert :unclassified = SafeAtom.intern!("bad key with spaces", :unclassified)
    assert :sentinel = SafeAtom.intern!(String.duplicate("x", 500), :sentinel)
  end

  test "intern!/1 keeps the original string when uninternable" do
    assert "bad key !!!" = SafeAtom.intern!("bad key !!!")
  end

  test "minted counter is monotonic and bounded-safe" do
    before = SafeAtom.minted()
    {:ok, _} = SafeAtom.intern("sa_count_#{System.unique_integer([:positive])}")
    assert SafeAtom.minted() >= before
  end
end
