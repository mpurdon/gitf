defmodule GiTF.Dashboard.SurfaceTest do
  @moduledoc """
  Three surfaces — the Catwalk, the old Cabinet, the Console — used to carry
  three copies of one palette under two sets of names: `--muted` on one,
  `--ink-3` on another, the same grey. A change to the design meant finding
  every copy, and missing one meant two products in one browser tab.

  There is one palette now, and these are the tests that keep it that way.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias GiTF.Dashboard.{CabinetLayouts, Console, Layouts, Surface}

  @surfaces [
    {"Catwalk", &Layouts.root/1},
    {"Cabinet", &CabinetLayouts.root/1},
    {"Console", &Console.Layouts.root/1}
  ]

  defp page(fun), do: render_component(fun, inner_content: {:safe, "<p>x</p>"})

  test "every token any dashboard file uses is defined in the one place" do
    defined =
      Regex.scan(~r/(--[a-z0-9-]+)\s*:/, Surface.base())
      |> Enum.map(&List.last/1)
      |> MapSet.new()

    unresolved =
      Path.wildcard("lib/gitf/dashboard/**/*.ex")
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/var\((--[a-z0-9-]+)\)/, File.read!(file))
        |> Enum.map(&{Path.basename(file), List.last(&1)})
      end)
      |> Enum.reject(fn {_file, token} -> MapSet.member?(defined, token) end)
      |> Enum.uniq()

    assert unresolved == [],
           "a token with no definition renders as nothing at all: #{inspect(unresolved)}"
  end

  test "the old names are gone, not aliased" do
    # An alias would have made the rename painless and permanent — two
    # vocabularies for one palette, for ever.
    for {old, new} <- [
          {"--text", "--ink"},
          {"--text-2", "--ink-2"},
          {"--muted", "--ink-3"},
          {"--line-2", "--line-soft"},
          {"--rail-active", "--rail-on"}
        ] do
      leaks =
        Path.wildcard("lib/gitf/dashboard/**/*.ex")
        |> Enum.filter(&(File.read!(&1) =~ "var(#{old})"))

      assert leaks == [], "#{old} survives in #{inspect(leaks)} — it is #{new} now"
    end
  end

  test "no token is used as both ink and ground" do
    # `--rail-active` (a wash) was renamed onto `--rail-on` (#FFFFFF, ink), and
    # the Catwalk's selected rail item became white on white — a rename that
    # kept the name and lost the role. Ink tokens are for `color`, never for a
    # background.
    # Not every ink token: `--ink-2` legitimately paints a small solid shape (a
    # toggle knob). These four are ink that only ever sits *on* something —
    # `--rail-on` and `--accent-ink` are defined by the ground they contrast
    # with, so painting a ground with one is white on white by construction.
    ink = ~w(--ink --rail-on --rail-text --accent-ink)

    for {name, fun} <- @surfaces, token <- ink do
      sheet = page(fun)

      refute sheet =~ ~r/background(?:-color)?\s*:\s*var\(#{token}\)/,
             "#{name} paints a background with #{token}, which is ink"
    end
  end

  test "each surface ships one complete stylesheet" do
    for {name, fun} <- @surfaces do
      html = page(fun)

      assert length(Regex.scan(~r/<style>/, html)) >= 1, "#{name} ships no stylesheet"

      # the shared half
      for probe <- ["--ink-3:", "--s4:", ".pill{", ".rows{"] do
        assert html =~ probe, "#{name} is missing #{probe} from the shared base"
      end

      # and nothing leaked through as text
      for leak <- ["Phoenix.HTML.raw", "Surface.base", "stylesheet()"] do
        refute html =~ leak, "#{name} emitted #{leak} as literal text"
      end
    end
  end

  test "each surface keeps its own furniture" do
    assert page(&Layouts.root/1) =~ ".rail-logo"
    assert page(&CabinetLayouts.root/1) =~ ".inspector"
    assert page(&Console.Layouts.root/1) =~ ".tnode"
  end
end
