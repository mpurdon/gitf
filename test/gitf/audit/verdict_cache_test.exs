defmodule GiTF.Audit.VerdictCacheTest do
  @moduledoc """
  Execution-efficiency B4, audit lane: the same command on the same tree
  gives the same verdict, so it is remembered — except an infra exit,
  which describes a broken toolchain, and a tree that could not be
  fingerprinted, which is no tree at all.
  """
  use GiTF.StoreCase

  alias GiTF.Audit.VerdictCache

  test "pass and fail verdicts are remembered per sector, command and tree" do
    assert VerdictCache.lookup("s1", "npm test", "ABC") == nil

    :ok =
      VerdictCache.store("s1", "npm test", "ABC", %{
        status: "failed",
        output: "boom",
        exit_code: 1
      })

    assert %{status: "failed", output: "boom", exit_code: 1} =
             VerdictCache.lookup("s1", "npm test", "ABC")

    # A different tree, command, or sector is a different question.
    assert VerdictCache.lookup("s1", "npm test", "DEF") == nil
    assert VerdictCache.lookup("s1", "npm run build", "ABC") == nil
    assert VerdictCache.lookup("s2", "npm test", "ABC") == nil
  end

  test "infra verdicts and unfingerprintable trees are never cached" do
    :ok =
      VerdictCache.store("s1", "npm test", "ABC", %{
        status: "infra_failure",
        output: "",
        exit_code: 127
      })

    assert VerdictCache.lookup("s1", "npm test", "ABC") == nil

    :ok = VerdictCache.store("s1", "npm test", nil, %{status: "passed", output: "", exit_code: 0})
    assert VerdictCache.lookup("s1", "npm test", nil) == nil
  end
end
