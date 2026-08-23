defmodule GiTF.ShellBaseRefTest do
  @moduledoc """
  `base_ref` is the ref a worktree was cut from, and `GiTF.Drift` compares
  against it to decide what "the base moved" means.

  It used to answer "origin/main" unconditionally, ignoring the base actually
  used. That was harmless while every ghost really was on main — and became a
  correctness bug the moment missions started building on a pull request's
  branch: every commit in the PR read as divergence, feeding the
  :risky/:conflicted classification and the auto-rebase decision. Seen in the
  wild as `base_ref="origin/main"` recorded against a base commit that was on
  the PR branch.
  """
  use ExUnit.Case, async: true

  @source File.read!("lib/gitf/shell.ex")

  test "an explicit base is recorded as the base_ref" do
    assert @source =~ ~r/defp detect_base_ref\(_sector_path, base\) when is_binary\(base\) and base != "", do: base/
  end

  test "create/3 passes the resolved base through" do
    assert @source =~ ~r/base_ref = detect_base_ref\(sector\.path, base_branch\)/
  end

  test "no explicit base still falls back to detection" do
    # Ordinary missions branch from sector HEAD and must keep the old label.
    assert @source =~ ~r/defp detect_base_ref\(sector_path, _base\), do: detect_base_ref\(sector_path\)/
    assert @source =~ ~r/match\?\(\{:ok, _\}, Git\.rev_parse\(sector_path, "origin\/main"\)\) -> "origin\/main"/
  end
end
