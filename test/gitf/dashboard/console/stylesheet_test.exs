defmodule GiTF.Dashboard.Console.StylesheetTest do
  @moduledoc """
  HEEx treats the contents of `<style>` and `<script>` as raw text, so an
  interpolation written inside a style tag is emitted **literally** — the page
  ships the source of the expression and none of the CSS, and it looks like a
  missing stylesheet rather than a template bug. The sheet is therefore built
  in Elixir and injected as one blob, and this is the test that says so.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias GiTF.Dashboard.{Console.Layouts, Surface}

  defp page do
    render_component(&Layouts.root/1, inner_content: {:safe, "<p>x</p>"}, page_title: "T")
  end

  test "the shared base and the Console's own CSS both reach the page" do
    html = page()

    assert html =~ "<style>"
    assert html =~ "</style>"

    # shared — tokens, reset, the component vocabulary
    for probe <- ["--ink-3:", "--s4:", "box-sizing", ".pill{", ".rows{", ".objhead{"] do
      assert html =~ probe, "the shared base is missing #{probe}"
    end

    # the Console's own — rail, tree, facets, rule editor
    for probe <- [".console{", ".tnode", ".facets{", ".rule{"] do
      assert html =~ probe, "the Console's own CSS is missing #{probe}"
    end
  end

  test "no expression is emitted as text" do
    html = page()

    for leak <- ["Phoenix.HTML.raw", "Surface.base", "stylesheet()", "{@"] do
      refute html =~ leak, "#{leak} reached the page as literal text"
    end
  end

  test "the page declares the csrf token exactly once" do
    # Two roots in one document is how the Console's own LiveSocket died before.
    html = page()
    assert length(Regex.scan(~r/(?:const|let|var) csrfToken/, html)) == 1
  end

  test "every token the shared CSS uses is one the shared CSS defines" do
    base = Surface.base()

    defined =
      Regex.scan(~r/(--[a-z0-9-]+)\s*:/, base) |> Enum.map(&List.last/1) |> MapSet.new()

    used = Regex.scan(~r/var\((--[a-z0-9-]+)\)/, base) |> Enum.map(&List.last/1) |> MapSet.new()

    assert MapSet.difference(used, defined) |> Enum.sort() == [],
           "a token used but never defined renders as nothing at all"
  end
end
