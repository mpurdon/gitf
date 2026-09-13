defmodule GiTF.Dashboard.TokensTest do
  @moduledoc """
  `--recon` was defined as its own `var()` — a cyclic reference CSS resolves
  to the guaranteed-invalid value, which discards every declaration that
  reads it. That silently unstyled the implementation, validation and
  simplify badges, the Timeline's phase_transition events and all four cache
  metrics. A token that refers to itself must never ship again.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GiTF.Dashboard.{CabinetLayouts, Console, Layouts, Surface}

  # Scanned from what each surface actually ships, not from its source: the
  # source also contains prose about this very bug, and a moduledoc quoting
  # `--recon: var(--recon)` would fail the test that exists to prevent it.
  @sheets [
    {"Catwalk", &Layouts.root/1},
    {"Cabinet", &CabinetLayouts.root/1},
    {"Console", &Console.Layouts.root/1}
  ]

  defp css(fun) do
    render_component(fun, inner_content: {:safe, ""})
    |> then(&Regex.scan(~r|<style>(.*?)</style>|s, &1))
    |> Enum.map_join("\n", &List.last/1)
  end

  defp declarations(css) do
    Regex.scan(~r/(--[a-z0-9-]+)\s*:\s*([^;}\n]+)/, css)
    |> Enum.map(fn [_, name, value] -> {name, String.trim(value)} end)
  end

  test "no design token is defined in terms of itself" do
    for {name, fun} <- @sheets, {token, value} <- declarations(css(fun)) do
      refute String.contains?(value, "var(#{token})"),
             "#{name}: #{token} is defined as #{value} — a cycle, which CSS discards"
    end
  end

  test "every token a surface reads is one its stylesheet defines" do
    for {name, fun} <- @sheets do
      sheet = css(fun)
      defined = declarations(sheet) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      used =
        Regex.scan(~r/var\((--[a-z0-9-]+)/, sheet)
        |> Enum.map(fn [_, token] -> token end)
        |> MapSet.new()

      missing = MapSet.difference(used, defined) |> MapSet.to_list()
      assert missing == [], "#{name} reads tokens nothing defines: #{inspect(missing)}"
    end
  end

  test "no surface redefines a shared token to something else" do
    shared = declarations(Surface.base()) |> Map.new()

    for {name, fun} <- @sheets,
        {token, value} <- declarations(css(fun)),
        Map.has_key?(shared, token),
        value != shared[token] do
      flunk("#{name} redefines #{token} as #{value} — it is #{shared[token]} everywhere else")
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
