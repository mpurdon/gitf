defmodule GiTF.Inquiry.PreviewTest do
  @moduledoc """
  The mockup contract, the storage lifetime, and the retention policy.

  Stage one made a `:choice` answerable in prose. That is the wrong shape
  for a visual decision — nobody picks an icon set from a sentence — and
  the operator's ask was explicit: *build a mockup of the choice so we
  can select the best visual option.*

  Four things here are load-bearing and each has its own describe block:

    * A mockup must not reach for the network. The renderer is headless
      Chromium pointed at a file an LLM wrote, on the box that holds the
      store, inside the tailnet.
    * Options are rendered in the SAME frame. A grid where each tile
      chose its own scale compares framing, not design.
    * The image OUTLIVES the worktree it was drawn in. Worktrees are
      reaped on completion and swept when orphaned, and an answered
      inquiry crosses a resume — so a preview stored in the tree would be
      a broken image on exactly the cards that mattered.
    * Nothing here may block a mission. Every failure degrades the option
      to its label; a question that cannot be answered is the single
      worst thing this machinery can produce.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Inquiry}
  alias GiTF.Inquiry.Preview

  # A renderer that writes a plausible file instead of driving a browser.
  # The suite must be able to assert the whole seam — contract checks,
  # storage layout, lifetime, degradation — on a box with no chromium,
  # which is every CI box and this laptop.
  defmodule StubRenderer do
    def render_file(source, output, opts) do
      send(self(), {:rendered, source, output, opts})

      case Process.get(:stub_render_result, :ok) do
        :ok ->
          File.mkdir_p!(Path.dirname(output))
          File.write!(output, "PNG:" <> Path.basename(source))
          {:ok, output}

        {:error, _} = err ->
          err
      end
    end
  end

  setup do
    previous_inquiries = GiTF.Config.Provider.get([:inquiries])
    previous_root = Application.get_env(:gitf, :visual_screenshots_root)
    previous_capture = Application.get_env(:gitf, :visual_capture_enabled)
    previous_renderer = Application.get_env(:gitf, :inquiry_preview_renderer)

    root = Path.join(System.tmp_dir!(), "gitf_preview_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(:gitf, :visual_screenshots_root, root)
    Application.put_env(:gitf, :visual_capture_enabled, true)
    Application.put_env(:gitf, :inquiry_preview_renderer, StubRenderer)
    GiTF.Config.Provider.put([:inquiries], previous_inquiries || %{})

    on_exit(fn ->
      GiTF.Config.Provider.put([:inquiries], previous_inquiries)
      restore(:visual_screenshots_root, previous_root)
      restore(:visual_capture_enabled, previous_capture)
      restore(:inquiry_preview_renderer, previous_renderer)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:gitf, key)
  defp restore(key, value), do: Application.put_env(:gitf, key, value)

  @mockup """
  <html><body style="margin:0;font-family:system-ui">
  <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><circle cx="5" cy="5" r="4"/></svg>
  </body></html>
  """

  # A mission whose `design` phase op has a live ghost, shell and
  # worktree — the op→ghost→shell chain `Preview.source_root/2` walks to
  # find the tree the mockup was drawn in.
  defp mission_with_worktree(files \\ %{"mockups/a.html" => @mockup}) do
    worktree =
      Path.join(System.tmp_dir!(), "gitf_worktree_#{:erlang.unique_integer([:positive])}")

    Enum.each(files, fn {relative, content} ->
      path = Path.join(worktree, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: "no-such-sector",
        worktree_path: worktree,
        branch: "ghost/g1",
        status: "active"
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{
        shell_id: shell.id,
        sector_id: "no-such-sector",
        status: "running"
      })

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "preview",
        goal: "pick an icon set",
        status: "active",
        sector_id: "no-such-sector",
        current_phase: "design",
        artifacts: %{},
        ops: [
          %{
            id: "op1",
            phase_job: true,
            phase: "design",
            ghost_id: ghost.id,
            status: "done",
            inserted_at: DateTime.utc_now()
          }
        ]
      })

    %{mission: mission, worktree: worktree}
  end

  defp question(options) do
    {:ok, validated} =
      Inquiry.validate(%{
        key: "icons",
        phase: "design",
        kind: :choice,
        prompt: "Which icon set?",
        options: options
      })

    validated
  end

  defp two_options(overrides \\ %{}) do
    [
      Map.merge(
        %{"label" => "Bars", "rationale" => "Magnitude", "preview" => "mockups/a.html"},
        overrides
      ),
      %{"label" => "Dots", "rationale" => "Category"}
    ]
  end

  defp attach(%{mission: mission}, options) do
    Preview.attach(mission, "design", question(options))
  end

  describe "the self-containment contract" do
    test "a plain inline mockup passes" do
      assert Preview.self_contained(@mockup) == :ok
    end

    test "an SVG namespace declaration is NOT a network reference" do
      # The one legitimate URL in a mockup, and the one every design ghost
      # writes by habit. A standalone .svg is invalid without it.
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)
      assert Preview.self_contained(svg) == :ok
    end

    test "an XHTML doctype is not a network reference either" do
      doc =
        ~s(<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0//EN" "http://www.w3.org/xhtml.dtd"><p>hi</p>)

      assert Preview.self_contained(doc) == :ok
    end

    test "a remote stylesheet is refused" do
      html = ~s(<link rel="stylesheet" href="https://cdn.example.com/x.css">)
      assert {:error, {:not_self_contained, reason}} = Preview.self_contained(html)
      assert reason =~ "://" or reason =~ "link"
    end

    test "a remote script is refused" do
      assert {:error, {:not_self_contained, _}} =
               Preview.self_contained(~s(<script src="https://cdn.example.com/x.js"></script>))
    end

    test "a local script src is still refused — the rule is self-containment, not origin" do
      assert {:error, {:not_self_contained, reason}} =
               Preview.self_contained(~s(<script src="./helper.js"></script>))

      assert reason =~ "script src"
    end

    test "a protocol-relative URL is refused" do
      assert {:error, {:not_self_contained, reason}} =
               Preview.self_contained(~s(<img src="//evil.example.com/pixel.png">))

      assert reason =~ "protocol-relative"
    end

    test "an iframe is refused — it is a file-read primitive that renders as an image" do
      assert {:error, {:not_self_contained, reason}} =
               Preview.self_contained(~s(<iframe src="/etc/passwd"></iframe>))

      assert reason =~ "iframe"
    end

    test "a file: reference is refused" do
      assert {:error, {:not_self_contained, _}} =
               Preview.self_contained(~s(<img src="file:/etc/hosts">))
    end

    test "an @import is refused" do
      assert {:error, {:not_self_contained, reason}} =
               Preview.self_contained("<style>@import 'other.css';</style>")

      assert reason =~ "@import"
    end

    test "fetch, XHR, WebSocket and sendBeacon are all refused" do
      for js <- [
            "fetch('/x')",
            "new XMLHttpRequest()",
            "new WebSocket('x')",
            "navigator.sendBeacon('x')"
          ] do
        assert {:error, {:not_self_contained, _}} =
                 Preview.self_contained("<script>#{js}</script>"),
               "expected #{js} to be refused"
      end
    end

    test "an inline data: URI is fine — it carries its own bytes" do
      html = ~s(<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">)
      assert Preview.self_contained(html) == :ok
    end
  end

  describe "the path contract" do
    test "a relative html path is accepted" do
      assert Preview.source_path?("mockups/a.html")
      assert Preview.source_path?("a.svg")
      assert Preview.source_path?("deep/nested/b.htm")
    end

    test "an absolute path is refused" do
      refute Preview.source_path?("/etc/passwd.html")
      refute Preview.source_path?("~/secrets.html")
    end

    test "a traversal is refused" do
      refute Preview.source_path?("../../../etc/passwd.html")
      refute Preview.source_path?("mockups/../../out.html")
    end

    test "a non-mockup extension is refused" do
      refute Preview.source_path?("mockups/a.png")
      refute Preview.source_path?("a.js")
      refute Preview.source_path?("")
    end
  end

  describe "rendering an option" do
    setup do: mission_with_worktree()

    test "the preview renders and the reference is stored on the option", ctx do
      assert %{options: [bars, dots]} = attach(ctx, two_options())

      assert %{png: png, width: 640, height: 400} = bars.preview
      assert File.regular?(png)
      assert bars.preview_error == nil

      # The option that never asked for one is untouched.
      assert dots.preview == nil
      assert dots.preview_error == nil
    end

    test "the image lands under the screenshots root, keyed by mission, key and option", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())
      {:ok, root} = Preview.root()

      assert String.starts_with?(bars.preview.png, root <> "/")
      assert bars.preview.png =~ "/inquiries/#{ctx.mission.id}/icons/bars.png"
    end

    test "the SOURCE is copied out beside the image", ctx do
      # The picture is evidence of a decision; the source is the only
      # thing that still explains it once the branch is gone.
      %{options: [bars, _]} = attach(ctx, two_options())

      assert File.read!(bars.preview.source) == @mockup
      assert Path.extname(bars.preview.source) == ".html"
    end

    test "every option is rendered in the SAME frame" do
      both = [
        %{"label" => "Bars", "preview" => "mockups/a.html"},
        %{"label" => "Dots", "preview" => "mockups/b.html"}
      ]

      ctx = mission_with_worktree(%{"mockups/a.html" => @mockup, "mockups/b.html" => @mockup})
      %{options: [bars, dots]} = attach(ctx, both)

      assert {bars.preview.width, bars.preview.height} == Preview.viewport()
      assert {dots.preview.width, dots.preview.height} == Preview.viewport()
    end

    test "the renderer is asked for a fixed viewport and NOT a full page", ctx do
      # full_page would let each mockup pick its own height, and the grid
      # would then compare framing rather than design.
      attach(ctx, two_options())

      assert_received {:rendered, _source, _output, opts}
      assert opts[:viewport] == Preview.viewport()
      assert opts[:full_page] == false
    end

    test "re-asking the same question does not pay for the browser twice", ctx do
      attach(ctx, two_options())
      assert_received {:rendered, _, _, _}

      attach(ctx, two_options())
      refute_received {:rendered, _, _, _}
    end
  end

  describe "degrading instead of blocking" do
    setup do: mission_with_worktree()

    test "a failed render leaves a text option and does NOT drop the question", ctx do
      Process.put(:stub_render_result, {:error, :timeout})

      assert %{options: [bars, dots]} = attach(ctx, two_options())

      assert bars.preview == nil
      assert bars.preview_error =~ "timed out"
      # Everything needed to answer is still there.
      assert bars.label == "Bars"
      assert bars.rationale == "Magnitude"
      assert dots.label == "Dots"
    after
      Process.delete(:stub_render_result)
    end

    test "a mockup that reaches for the network degrades and says which rule it broke" do
      ctx =
        mission_with_worktree(%{
          "mockups/a.html" => ~s(<link rel="stylesheet" href="https://cdn.example.com/x.css">)
        })

      %{options: [bars, _]} = attach(ctx, two_options())

      assert bars.preview == nil
      assert bars.preview_error =~ "reaches outside itself"
    end

    test "an oversized mockup degrades and names the limit" do
      ctx =
        mission_with_worktree(%{
          "mockups/a.html" => String.duplicate("x", Preview.max_source_bytes() + 1)
        })

      %{options: [bars, _]} = attach(ctx, two_options())

      assert bars.preview == nil
      assert bars.preview_error =~ "KB limit"
    end

    test "a missing mockup degrades", ctx do
      %{options: [bars, _]} = attach(ctx, two_options(%{"preview" => "mockups/absent.html"}))

      assert bars.preview == nil
      assert bars.preview_error =~ "no such file"
    end

    test "a mission whose worktree is already gone degrades rather than guessing at another tree",
         ctx do
      File.rm_rf!(ctx.worktree)

      %{options: [bars, _]} = attach(ctx, two_options())

      assert bars.preview == nil
      assert bars.preview_error =~ "no live worktree"
    end

    test "with visual capture off, the option still asks — and says why there is no picture",
         ctx do
      Application.put_env(:gitf, :visual_capture_enabled, false)
      GiTF.Config.Provider.put([:inquiries, :previews_enabled], false)

      %{options: [bars, _]} = attach(ctx, two_options())

      assert bars.preview == nil
      assert bars.preview_error =~ "previews are off"
      assert bars.label == "Bars"
    end

    test "a traversal in the mockup path is dropped by validation, never rendered", ctx do
      %{options: [bars, _]} = attach(ctx, two_options(%{"preview" => "../../../etc/passwd.html"}))

      refute_received {:rendered, _, _, _}
      assert bars.preview == nil
      assert bars.preview_error =~ "relative"
    end
  end

  describe "the lifetime — a preview outlives the worktree it was drawn in" do
    setup do: mission_with_worktree()

    test "reaping the worktree does not take the image with it", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())

      {:ok, inquiry, :asked} =
        Inquiry.ask(ctx.mission.id, %{
          key: "icons",
          phase: "design",
          kind: :choice,
          prompt: "Which icon set?",
          options: [bars, %{label: "Dots"}]
        })

      # What Shell.remove/2 does when the mission completes, and what the
      # orphan sweep does five minutes after it goes quiet.
      File.rm_rf!(ctx.worktree)
      refute File.dir?(ctx.worktree)

      assert {:ok, png} = Preview.read(inquiry, "bars")
      assert png != ""
    end

    test "a pruned image degrades gracefully instead of raising", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())

      {:ok, inquiry, :asked} =
        Inquiry.ask(ctx.mission.id, %{
          key: "icons",
          phase: "design",
          kind: :choice,
          prompt: "Which icon set?",
          options: [bars, %{label: "Dots"}]
        })

      # This is what an INHERITED answer looks like after retention has
      # run: the decision is still readable, the picture is not there.
      File.rm!(bars.preview.png)

      assert Preview.read(inquiry, "bars") == {:error, :not_found}
      # And the URL is still offered, so the card's onerror can fold it
      # away rather than the card having to stat the disk on every render.
      assert Preview.url(inquiry, bars) =~ "/preview/bars"
    end

    test "a request cannot name a file — an unknown option id reads nothing", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())

      {:ok, inquiry, :asked} =
        Inquiry.ask(ctx.mission.id, %{
          key: "icons",
          phase: "design",
          kind: :choice,
          prompt: "Which icon set?",
          options: [bars, %{label: "Dots"}]
        })

      assert Preview.read(inquiry, "../../../../etc/passwd") == {:error, :not_found}
      assert Preview.read(inquiry, "dots") == {:error, :not_found}
    end

    test "an option with no preview has no URL" do
      assert Preview.url(%{id: "i1"}, %{id: "dots", preview: nil}) == nil
    end
  end

  describe "retention" do
    setup do: mission_with_worktree()

    test "an image past the retention window is deleted", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())

      age(bars.preview.png, 31)
      age(bars.preview.source, 31)

      assert %{removed: 2, freed_bytes: freed} = Preview.prune()
      assert freed > 0
      refute File.regular?(bars.preview.png)
    end

    test "a fresh image is left alone", ctx do
      %{options: [bars, _]} = attach(ctx, two_options())

      assert %{removed: 0} = Preview.prune()
      assert File.regular?(bars.preview.png)
    end

    test "an OPEN question's image is never pruned, however old it is", ctx do
      # The gate does not auto-answer, so a question can honestly outlive
      # the window while still being the thing a human is about to look
      # at. Deleting the picture out from under it would be the retention
      # policy quietly answering the question.
      %{options: [bars, _]} = attach(ctx, two_options())

      {:ok, _inquiry, :asked} =
        Inquiry.ask(ctx.mission.id, %{
          key: "icons",
          phase: "design",
          kind: :choice,
          prompt: "Which icon set?",
          options: [bars, %{label: "Dots"}]
        })

      age(bars.preview.png, 400)
      age(bars.preview.source, 400)

      assert %{removed: 0} = Preview.prune()
      assert File.regular?(bars.preview.png)
    end

    test "the byte budget evicts oldest-first when age alone would not", ctx do
      # Age alone does not bound a directory: a burst of previewed
      # questions inside one window is under the age limit and over the
      # disk. Same lesson EventStore.cap/1 learned from 194,727 rows.
      attach(ctx, two_options())
      GiTF.Config.Provider.put([:inquiries, :preview_budget_mb], 1)

      {:ok, root} = Preview.root()
      big = Path.join([root, "inquiries", ctx.mission.id, "icons", "big.png"])
      File.write!(big, String.duplicate("x", 2 * 1024 * 1024))
      age(big, 1)

      assert %{removed: removed} = Preview.prune()
      assert removed > 0
      refute File.regular?(big)
    end

    test "pruning an empty tree is a no-op, not a crash" do
      assert Preview.prune() == %{removed: 0, freed_bytes: 0}
    end
  end

  describe "the invitation's mockup contract" do
    test "it is offered when a mockup could actually be rendered" do
      block = Preview.contract_block()

      assert block =~ "self-contained"
      assert block =~ "No network requests"
      assert block =~ "#{elem(Preview.viewport(), 0)}x#{elem(Preview.viewport(), 1)}"
      assert block =~ "preview"
      assert block =~ Preview.mockup_dir()
      assert block =~ "never committed"
    end

    test "it is silent when the factory cannot render — inviting pictures nobody renders wastes output" do
      Application.put_env(:gitf, :visual_capture_enabled, false)
      assert Preview.contract_block() == ""
    end
  end

  defp age(path, days) do
    seconds = days * 86_400
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -seconds, :second)
    File.touch!(path, NaiveDateTime.to_erl(at))
  end
end
