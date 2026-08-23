defmodule GiTF.Dashboard.FileDivergenceTest do
  @moduledoc """
  The Compare tab's central claim is "here is where the strategies actually
  differ". If this computation is wrong, the page argues for the wrong design.
  """
  use ExUnit.Case, async: true

  import GiTF.Dashboard.Helpers, only: [file_divergence: 1]

  defp design(files), do: %{"components" => Enum.map(files, &%{"files" => [&1]})}

  test "files in every design are agreed, not divergent" do
    cmp =
      file_divergence([
        {"minimal", design(["a.rs", "b.ts"])},
        {"normal", design(["a.rs", "b.ts"])}
      ])

    assert cmp.total == 2
    assert cmp.agreed == 2
    assert Enum.all?(cmp.rows, fn {_, _, all?} -> all? end)
  end

  test "a file only one strategy touches is divergent and names that strategy" do
    cmp =
      file_divergence([
        {"minimal", design(["a.rs"])},
        {"normal", design(["a.rs", "store.rs"])}
      ])

    assert cmp.agreed == 1
    assert {"store.rs", ["normal"], false} in cmp.rows
  end

  test "designs that have not landed yet are excluded from the comparison" do
    # Otherwise a still-generating strategy makes every file look divergent.
    cmp =
      file_divergence([
        {"minimal", design(["a.rs"])},
        {"normal", design(["a.rs"])},
        {"complex", nil}
      ])

    assert cmp.strategies == ["minimal", "normal"]
    assert cmp.agreed == 1
    assert cmp.total == 1
  end

  test "counts a file once when several components in one design touch it" do
    both = %{
      "components" => [
        %{"files" => ["models.rs", "store.rs"]},
        %{"files" => ["models.rs"]}
      ]
    }

    cmp = file_divergence([{"normal", both}])

    assert cmp.total == 2
    assert cmp.agreed == 2
  end

  test "handles components with no files and designs with no components" do
    cmp =
      file_divergence([
        {"minimal", %{"components" => [%{"name" => "no files here"}]}},
        {"normal", %{}}
      ])

    assert cmp.total == 0
    assert cmp.rows == []
  end

  test "returns an empty comparison when no design has landed" do
    cmp = file_divergence([{"minimal", nil}, {"normal", nil}])

    assert cmp.strategies == []
    assert cmp.total == 0
  end
end
