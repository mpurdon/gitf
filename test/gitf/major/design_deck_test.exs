defmodule GiTF.Major.DesignDeckTest do
  @moduledoc """
  The deck exists to leave the tailnet, so its defining property is that the
  file stands alone: no stylesheet, no script, no font, no image fetched from
  anywhere. A deck that needs the dashboard to render is the dashboard.
  """
  use GiTF.StoreCase

  alias GiTF.Major.DesignDeck

  defp mission_with(artifacts) do
    {:ok, m} = GiTF.Missions.create(%{goal: "add configurable approve messages"})
    Enum.each(artifacts, fn {k, v} -> GiTF.Missions.store_artifact(m.id, k, v) end)
    m
  end

  defp design(files),
    do: %{"components" => Enum.map(files, &%{"files" => [&1]}), "risks" => ["a risk"]}

  test "refuses when there is nothing to show" do
    m = mission_with(%{})
    assert {:error, :nothing_to_show} = DesignDeck.render(m.id)
  end

  test "renders from designs alone, without a brief" do
    # A mission that never had a brief generated is still worth sending.
    m = mission_with(%{"design_normal" => design(["a.rs"])})
    assert {:ok, html} = DesignDeck.render(m.id)
    assert html =~ "<!doctype html>"
    assert html =~ "normal"
  end

  test "is entirely self-contained" do
    m =
      mission_with(%{
        "design_normal" => design(["a.rs"]),
        "design_report" => %{"headline" => "Same shape, different rigor."}
      })

    {:ok, html} = DesignDeck.render(m.id)

    # Nothing may be fetched at open time — the reader may have no network,
    # and will certainly have no route to this factory.
    refute html =~ "<link"
    refute html =~ "src=\"http"
    refute html =~ "@import"
    refute html =~ "//fonts."
    assert html =~ "<style>"
    assert html =~ "<script>"
  end

  test "carries the argument when a brief exists" do
    m =
      mission_with(%{
        "design_normal" => design(["a.rs"]),
        "design_report" => %{
          "headline" => "Same shape, different rigor.",
          "convergence" => "All three touched the same files.",
          "decision" => "normal won on rigor.",
          "designs" => [%{"strategy" => "normal", "character" => "careful", "notable" => ["saw the race"], "missed" => []}],
          "watch_items" => [%{"concern" => "cross-window save", "why_it_matters" => "lost update"}]
        },
        "review" => %{"selected_design" => "normal", "approved" => true}
      })

    {:ok, html} = DesignDeck.render(m.id)

    assert html =~ "Same shape, different rigor."
    assert html =~ "All three touched the same files."
    assert html =~ "normal won on rigor."
    assert html =~ "saw the race"
    assert html =~ "cross-window save"
  end

  test "escapes model-authored text" do
    # Every string on a slide came from a model. A stray angle bracket must
    # not be able to restructure the page.
    m =
      mission_with(%{
        "design_normal" => design(["a.rs"]),
        "design_report" => %{"headline" => "<script>alert(1)</script> & <b>bold</b>"}
      })

    {:ok, html} = DesignDeck.render(m.id)

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "&amp;"
  end

  test "the filename identifies the mission" do
    assert DesignDeck.filename("msn-ff3fc6") == "msn-ff3fc6-design-decision.html"
  end

  test "a missing mission is an error, not a crash" do
    assert {:error, :not_found} = DesignDeck.render("msn-nope")
  end
end
