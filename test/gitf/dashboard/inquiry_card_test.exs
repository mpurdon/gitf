defmodule GiTF.Dashboard.InquiryCardTest do
  @moduledoc """
  The one rendering of an operator question, shared by the Questions queue
  and the mission detail page.

  Stage one's card was a list of labelled buttons, and for a decision that
  reads as prose that is right. A VISUAL decision asked as prose is a
  decision the operator has to imagine before they can make it — which is
  the thing the operator asked to fix — so a `:choice` whose options carry
  mockups renders as a grid of images instead.

  Two properties carry the whole component and both are asserted here:

    * The arm is chosen on whether an option ACTUALLY has an image, not on
      whether one was asked for. A question whose mockups all failed must
      fall back to the labelled list rather than draw a grid of empty
      frames.
    * The picture never replaces the answer. Label and rationale are
      rendered in both arms, so a preview that was pruned, or that 404s,
      leaves a question the operator can still read — which is exactly
      what an old inherited answer looks like after retention has run.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GiTF.Dashboard.InquiryCard

  defp card(inquiry) do
    render_component(&InquiryCard.inquiry_card/1, inquiry: inquiry)
  end

  defp choice(options, overrides \\ %{}) do
    Map.merge(
      %{
        id: "inq-1",
        mission_id: "msn-1",
        phase: "design",
        key: "icons",
        kind: :choice,
        status: "open",
        prompt: "Which priority indicator?",
        options: options,
        asked_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp option(id, label, extra \\ %{}) do
    Map.merge(
      %{id: id, label: label, rationale: "why #{label}", preview: nil, preview_error: nil},
      extra
    )
  end

  defp previewed(id, label) do
    option(id, label, %{preview: %{png: "/tmp/#{id}.png", width: 640, height: 400}})
  end

  describe "choosing the arm" do
    test "a choice with previews renders an image grid" do
      html = card(choice([previewed("bars", "Bars"), previewed("dots", "Dots")]))

      assert html =~ "<img"
      assert html =~ "/dashboard/questions/inq-1/preview/bars"
      assert html =~ "/dashboard/questions/inq-1/preview/dots"
      assert html =~ "grid-template-columns"
    end

    test "a choice with no previews renders the plain button list" do
      html = card(choice([option("grid", "Grid"), option("list", "List")]))

      refute html =~ "<img"
      refute html =~ "/preview/"
      assert html =~ "Grid"
      assert html =~ "List"
    end

    test "a choice whose mockups ALL failed falls back to the list, not a grid of empty frames" do
      options = [
        option("bars", "Bars", %{preview_error: "the renderer timed out"}),
        option("dots", "Dots", %{preview_error: "the renderer timed out"})
      ]

      html = card(choice(options))

      refute html =~ "<img"
      assert html =~ "Bars"
      assert html =~ "Dots"
    end

    test "a mixed choice still grids, and the option with no image says why" do
      options = [
        previewed("bars", "Bars"),
        option("dots", "Dots", %{preview_error: "no such file in the worktree"})
      ]

      html = card(choice(options))

      assert html =~ "<img"
      assert html =~ "no such file in the worktree"
      assert html =~ "Dots"
    end
  end

  describe "the picture never replaces the answer" do
    test "label and rationale are rendered beside every mockup" do
      html = card(choice([previewed("bars", "Bars"), previewed("dots", "Dots")]))

      assert html =~ "Bars"
      assert html =~ "why Bars"
      assert html =~ "why Dots"
    end

    test "each tile is still the button that answers the question" do
      html = card(choice([previewed("bars", "Bars"), previewed("dots", "Dots")]))

      assert html =~ ~s(phx-click="answer_inquiry")
      assert html =~ ~s(phx-value-answer="bars")
      assert html =~ ~s(phx-value-answer="dots")
    end

    # A pruned or 404ing image must not leave a broken-picture card. The
    # frame carries its own fallback text and the image hides itself, so
    # the tile degrades in place to a labelled option — which is what an
    # inherited answer looks like once retention has taken the picture.
    test "a broken image folds itself away and reveals the frame's fallback" do
      html = card(choice([previewed("bars", "Bars"), previewed("dots", "Dots")]))

      assert html =~ "onerror"
      assert html =~ "no preview"
    end

    test "the image is described for anyone not looking at it" do
      html = card(choice([previewed("bars", "Bars"), previewed("dots", "Dots")]))
      assert html =~ ~s(alt="Mockup of Bars")
    end
  end

  describe "the other kinds are untouched" do
    test "an answered previewed choice shows the decision, not the grid" do
      html =
        card(
          choice([previewed("bars", "Bars"), previewed("dots", "Dots")], %{
            status: "answered",
            answer: "bars",
            answer_label: "Bars",
            answered_by: "operator",
            answered_at: DateTime.utc_now()
          })
        )

      refute html =~ "<img"
      assert html =~ "answered"
      assert html =~ "Bars"
    end

    test "a confirm still renders yes and no" do
      html = card(choice([], %{kind: :confirm, options: []}))

      assert html =~ ">Yes<"
      assert html =~ ">No<"
    end

    test "a text question still renders a textarea" do
      html = card(choice([], %{kind: :text, options: []}))

      assert html =~ "<textarea"
    end

    test "an unrenderable kind still says so rather than showing a dead card" do
      html = card(choice([], %{kind: :essay, options: []}))

      assert html =~ "Unrecognised question kind"
    end
  end
end
