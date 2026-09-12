defmodule GiTF.Dashboard.TokensTest do
  @moduledoc """
  `--recon` was defined as its own `var()` — a cyclic reference CSS resolves
  to the guaranteed-invalid value, which discards every declaration that
  reads it. That silently unstyled the implementation, validation and
  simplify badges, the Timeline's phase_transition events and all four cache
  metrics. A token that refers to itself must never ship again.
  """
  use ExUnit.Case, async: true

  @sheets ["lib/gitf/dashboard/layouts.ex", "lib/gitf/dashboard/cabinet_layouts.ex"]

  defp declarations(file) do
    Regex.scan(~r/(--[a-z0-9-]+)\s*:\s*([^;}\n]+)/, File.read!(file))
    |> Enum.map(fn [_, name, value] -> {name, String.trim(value)} end)
  end

  test "no design token is defined in terms of itself" do
    for file <- @sheets, {name, value} <- declarations(file) do
      refute String.contains?(value, "var(#{name})"),
             "#{file}: #{name} is defined as #{value} — a cycle, which CSS discards"
    end
  end

  test "every token a stylesheet reads is one it also defines" do
    for file <- @sheets do
      src = File.read!(file)
      defined = declarations(file) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      used =
        Regex.scan(~r/var\((--[a-z0-9-]+)/, src)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      missing = MapSet.difference(used, defined) |> MapSet.to_list()
      assert missing == [], "#{file} reads tokens it never defines: #{inspect(missing)}"
    end
  end

  test "the colour modifiers the templates apply are actually styled" do
    sheet = File.read!("lib/gitf/dashboard/layouts.ex")

    for cls <- ~w(green blue yellow red) do
      assert String.contains?(sheet, ".sidebar-stat-value.#{cls}"),
             ".sidebar-stat-value.#{cls} is applied by mission detail and styled nowhere"
    end

    assert String.contains?(sheet, ".card-value.purple"),
           ".card-value.purple is applied by the overview and styled nowhere"
  end

  test "the Cabinet inspector's rules target the element that exists" do
    sheet = File.read!("lib/gitf/dashboard/cabinet_layouts.ex")
    tpl = File.read!("lib/gitf/dashboard/live/cabinet_live.ex")

    refute String.contains?(sheet, ".insp .kv"),
           "scoped to .insp, but the aside is class=\"inspector\" — the kv grid never applied"

    assert String.contains?(tpl, ~s(class="inspector"))
    assert String.contains?(sheet, ".inspector .kv")
  end
end
