defmodule GiTF.Inquiry.Preview do
  @moduledoc """
  MOCKUPS — turning "which of these looks right?" into something the
  operator can actually look at.

  Stage one gave a `:choice` a label and a rationale, and for most
  decisions that is enough: *ship the migration in one release or two*
  reads fine as prose. A VISUAL decision does not. Nobody can pick an
  icon set, a density, a colour ramp or a card layout from a sentence
  describing it, and asking them to is a question dressed as a taste
  call that actually demands they imagine the answer. The operator asked
  for exactly this: "I want the planner to build a mockup of the choice
  so that we can select the best visual option."

  So a design ghost may write one small self-contained file per option,
  name it on `option.preview`, and this module renders each one at a
  FIXED viewport and stores the image somewhere the Catwalk can serve
  for as long as the question can be looked at.

  ## What a mockup is, and what it deliberately is not

  A mockup is **one self-contained HTML or SVG file that the design
  ghost writes by hand**. It is not a build of the real application with
  the option applied. That second thing exists — it is the tournament —
  and it costs N full implementations to answer one question about an
  icon. The whole value of this gate is that it fires BEFORE the
  expensive work, so paying implementation prices to ask the question
  would invert it.

  The contract, all of it enforced by `attach/3` and none of it advisory:

    * **One file per option**, referenced by a path RELATIVE to the
      asking ghost's worktree. `.html`, `.htm` or `.svg`.
    * **Self-contained.** No network, at all. `self_contained?/1` refuses
      a file containing `://`, a `<link>`, a `<script src>`, an
      `<iframe>`/`<object>`/`<embed>`, `@import`, `fetch(`,
      `XMLHttpRequest`, `WebSocket`, `EventSource`, `sendBeacon` or a
      protocol-relative `src`/`href`. Inline `<style>`, inline `<script>`
      and `data:` URIs are the way to do everything. This is a hard
      refusal rather than a sandbox because the renderer must not be a
      network client: it runs headless Chromium on a file the LLM wrote,
      inside the tailnet, on the box that holds the store.
    * **A size bound** — `max_source_bytes/0`, default 128 KB. A
      hand-drawn mockup is single-digit kilobytes; the bound is there so
      a ghost that inlines a megabyte of base64 raster is refused rather
      than quietly charged to a small EBS volume.
    * **A fixed viewport** — `viewport/0`, default 640x400, `full_page:
      false`. This is the one constraint that is about the operator
      rather than safety. Options are meant to be compared SIDE BY SIDE;
      if each mockup picks its own scale the grid compares framing
      instead of design, which is the wrong question rendered
      convincingly.

  ## Degrading is always allowed; blocking never is

  Every failure path here returns the option with `preview: nil` and a
  short `preview_error`, and the question is asked anyway as a plain
  labelled choice. That direction is not negotiable. `GiTF.Inquiry`'s
  worst outcome is a mission parked on a question no human can act on,
  and "the mockup did not render" must never be promoted into that. A
  missing image costs the operator some context; a blank card costs them
  the mission.

  The renderer is therefore also allowed to be absent. Previews need
  BOTH `[:inquiries, :previews_enabled]` (default true) and the
  factory-wide `:visual_capture_enabled` (default FALSE), because
  rendering spawns headless Chromium and that switch is the operator's
  existing statement about whether this factory may do that at all. With
  capture off, every previewed question still asks — as text.

  ## Where the images live, and why not in the worktree

  An inquiry outlives the tree its mockup was drawn in. Worktrees are
  reaped when a mission completes (`Orchestrator.cleanup_mission_shells/2`
  via `Scoring.finish/1`) and swept every ~5 minutes when they go orphan
  (`Shell.cleanup_orphans/0`), while an answered inquiry crosses a
  resume through the `answered_inquiries` register and can be rendered
  on a card months later. A preview stored under
  `<sector>/ghosts/<ghost_id>/` would therefore be a broken image on
  every card that mattered.

  So `attach/3` COPIES the source out of the worktree and renders the
  copy, into

      <gitf_root>/.gitf/screenshots/inquiries/<mission_id>/<key>/<option_id>.png
      <gitf_root>/.gitf/screenshots/inquiries/<mission_id>/<key>/<option_id>.html

  reusing `GiTF.Visual.Capture`'s screenshots root — the same directory
  its `allowed_output_path/1` containment check already polices, so
  there is one place a headless browser is permitted to write rather
  than two. The `.html` is kept beside the `.png` because the image is
  evidence of a decision and the source is the only thing that explains
  it after the branch is gone.

  ## Retention, and the disk budget behind it

  This is the first on-disk retention policy in the factory. Nothing
  prunes `.gitf/run/*.log`, `.gitf/missions/`, `.gitf/planning/` or
  `.gitf/screenshots/` today, and that is exactly why previews must not
  join them: the box is a small EBS volume that CANNOT be shrunk once
  grown, `GiTF.Medic.check_disk_space/0` already warns when `.gitf`
  passes 1 GB, and `Tachikoma.cleanup_if_low_disk/0` starts deleting
  worktrees at 200 MB free. A feature that writes images forever would
  spend the operator's disk on decisions they made last quarter.

  `prune/0` runs from Tachikoma's ~50-minute sweep beside
  `prune_old_store_data/0` and enforces two limits, because either alone
  is insufficient (the lesson `GiTF.EventStore.cap/1` learned from
  194,727 rows all younger than the window):

    * **Age** — `[:inquiries, :preview_retention_days]`, default 30.
    * **A total byte cap** — `[:inquiries, :preview_budget_mb]`, default
      128, oldest first. 128 MB is a deliberate eighth of Medic's `.gitf`
      warn threshold and holds roughly three thousand previews at the
      fixed viewport, which at a budget of three questions per mission is
      years of asking.

  One exclusion overrides both: **a preview belonging to an OPEN inquiry
  is never pruned.** This gate does not auto-answer, so a question can
  legitimately be older than the retention window and still be the thing
  a human is about to look at. Deleting the picture out from under a
  waiting decision would be the retention policy quietly answering it.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Config.Provider, as: ConfigProvider

  @source_extensions ~w(.html .htm .svg)

  # 128 KB. A self-contained mockup drawn in HTML/CSS/SVG is single-digit
  # kilobytes; anything approaching this bound is inlining raster, which
  # is not what a mockup is for and is charged to the same small volume
  # the store lives on.
  @max_source_bytes 128 * 1024

  # 640x400 with full_page OFF. The fixed frame is the point: options are
  # compared side by side, and a mockup free to choose its own height
  # would be compared on framing rather than on design.
  @viewport {640, 400}

  # `.gitf/screenshots/inquiries/<mission>/<key>/<option>.png`
  @subdir "inquiries"

  # Where a ghost is told to draw. Dot-prefixed and factory-named so it is
  # unmistakably not the project's, and listed in `GiTF.Git.residue_paths/0`
  # so it can never be staged, committed, or fingerprinted. msn-0434e9
  # shipped three mockups into cora PR #20 because they lived in a plain
  # `mockups/` that nothing owned.
  @mockup_dir ".gitf-mockups"

  @type preview :: %{
          png: Path.t(),
          source: Path.t() | nil,
          width: pos_integer(),
          height: pos_integer(),
          bytes: non_neg_integer(),
          rendered_at: String.t()
        }

  # -- The contract, as the ghost is told it -----------------------------------

  @doc "The worktree-relative directory mockups are drawn in, with trailing slash."
  @spec mockup_dir() :: String.t()
  def mockup_dir, do: @mockup_dir <> "/"

  @doc """
  The mockup contract, rendered for a phase prompt.

  Appended to `GiTF.Inquiry.invitation_block/2` only when previews can
  actually be produced — a ghost invited to draw mockups by a factory
  whose renderer is off would spend its output on files nobody renders,
  and then be told, in the card, that its pictures failed.
  """
  @spec contract_block() :: String.t()
  def contract_block do
    if available?() do
      {w, h} = viewport()

      """

      ### Showing the options instead of describing them

      If the decision is VISUAL — an icon set, a layout, a density, a
      colour treatment — describing the options in prose asks the operator
      to imagine the answer. Draw them instead.

      For each option, write ONE self-contained file under
      `#{mockup_dir()}` in your worktree and name it on that option's
      `preview`, as a path relative to your worktree root:

      ```json
      {"id": "flat", "label": "Flat bars", "rationale": "Reads as level, not progress.",
       "preview": "#{mockup_dir()}priority-flat.html"}
      ```

      Rules, all enforced — a file that breaks one is dropped and the
      option falls back to its label and rationale:

      - Under `#{mockup_dir()}`, whatever path the goal or anyone else
        suggests. That directory is factory residue: it is never staged,
        never committed and never part of the deliverable. A mockup is
        evidence for a decision, not work product — once the operator has
        answered, it has done its job and nothing downstream recreates,
        preserves or ships it.
      - `.html`, `.htm` or `.svg`, under #{div(max_source_bytes(), 1024)} KB.
      - **Completely self-contained. No network requests of any kind.**
        Inline every style in a `<style>` tag; draw with inline SVG, CSS
        and Unicode; embed anything else as a `data:` URI. No `<link>`,
        no `<script src>`, no `<iframe>`, no `@import`, no web fonts, no
        `fetch`. Use a system font stack.
      - It is rendered at exactly #{w}x#{h}, no scrolling. Compose for
        that frame and give every option the SAME framing, scale and
        background — the operator is comparing the designs, and anything
        else that differs between the images is noise they will read as
        signal.
      - Draw the thing in a realistic context, not on a blank page: the
        icons in the actual row they will sit in, the layout with real
        labels. An option shown out of context is not the option.

      Still write a real `label` and `rationale` for every option. The
      image can fail to render, and the words are what the operator gets
      when it does.
      """
    else
      ""
    end
  end

  # -- Rendering at the seam ---------------------------------------------------

  @doc """
  Renders every previewable option of `question` and returns the question
  with each `option.preview` replaced by a stored image reference.

  Called by `GiTF.Inquiry.Gate.raise_all/3` between validation and
  recording: validation is pure and cheap and settles whether the
  question is answerable at all, and there is no reason to run a browser
  for a question that is about to be refused.

  NEVER raises and never returns an error. An option whose mockup is
  missing, oversized, reaching for the network or simply unrenderable
  comes back with `preview: nil` and a `preview_error` naming the reason,
  and is asked as an ordinary labelled option.
  """
  @spec attach(map(), String.t(), map()) :: map()
  def attach(mission, phase, %{kind: :choice, options: options} = question)
      when is_list(options) do
    if enabled?() and Enum.any?(options, &previewable?/1) do
      %{question | options: Enum.map(options, &render_option(mission, phase, question, &1))}
    else
      disable_previews(question)
    end
  end

  def attach(_mission, _phase, question), do: question

  # With previews off (or nothing to draw), an option that named a mockup
  # must still say WHY there is no picture. Silence here reads to the
  # operator as "the ghost did not bother", when the truth is a config
  # flag they own.
  defp disable_previews(%{kind: :choice, options: options} = question) do
    if Enum.any?(options, &previewable?/1) do
      %{question | options: Enum.map(options, &note_disabled/1)}
    else
      question
    end
  end

  defp disable_previews(question), do: question

  # Only when there is no image to explain the absence of. A question
  # re-asked after the flag was turned off still holds the picture it was
  # rendered with, and an error note under a working mockup would be a
  # lie about the one thing the operator is looking at.
  defp note_disabled(option) do
    if previewable?(option) and is_nil(option[:preview]) do
      %{option | preview_error: disabled_reason()}
    else
      option
    end
  end

  defp previewable?(option), do: is_binary(option[:preview_source])

  defp render_option(mission, phase, question, option) do
    if previewable?(option) do
      case build(mission, phase, question, option) do
        {:ok, preview} ->
          %{option | preview: preview, preview_error: nil}

        {:error, reason} ->
          Logger.warning(
            "Quest #{mission.id}: mockup #{inspect(option[:preview_source])} for " <>
              "#{phase}/#{question.key} option #{option.id} was not rendered " <>
              "(#{describe(reason)}) — asking as a text option instead"
          )

          %{option | preview: nil, preview_error: describe(reason)}
      end
    else
      option
    end
  end

  defp build(mission, phase, question, option) do
    png = png_path(mission.id, question.key, option.id)

    # The same question re-asked on a later advance sweep, or re-emitted by
    # a phase that was re-dispatched, must not pay for the browser twice.
    # The path is deterministic in {mission, key, option}, and a question's
    # key is its stable identity, so an image already at that path is by
    # definition this option's image.
    if File.regular?(png) do
      {:ok, describe_existing(png)}
    else
      with {:ok, root} <- source_root(mission, phase),
           {:ok, bytes} <- read_source(root, option[:preview_source]),
           :ok <- self_contained(bytes),
           {:ok, source_copy} <- stage_source(png, option[:preview_source], bytes),
           {:ok, _} <- render(source_copy, png) do
        {:ok, describe_existing(png, source_copy)}
      end
    end
  end

  # The mockup was written by the ghost that asked, so it lives in that
  # ghost's worktree — resolved through the phase op rather than guessed
  # at, the same op→ghost→shell chain `Major.Topology.variant_shell/2`
  # walks. A phase with no live worktree (re-dispatch after a reap, a
  # replayed artifact) degrades; it does not guess at another tree.
  defp source_root(mission, phase) do
    with %{ghost_id: ghost_id} when is_binary(ghost_id) <- latest_phase_op(mission, phase),
         %{shell_id: shell_id} when is_binary(shell_id) <- Archive.get(:ghosts, ghost_id),
         %{worktree_path: worktree} when is_binary(worktree) <- Archive.get(:shells, shell_id),
         true <- File.dir?(worktree) do
      {:ok, Path.expand(worktree)}
    else
      _ -> {:error, :no_worktree}
    end
  rescue
    _ -> {:error, :no_worktree}
  end

  defp latest_phase_op(mission, phase) do
    (Map.get(mission, :ops) || [])
    |> Enum.filter(&(&1[:phase_job] == true and &1[:phase] == phase))
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
  end

  # `GiTF.Inquiry.normalize_option/1` has already refused an absolute path
  # and any `..` segment. Re-checking containment AFTER expansion is not
  # redundancy for its own sake: a symlink inside the worktree, or a path
  # that only escapes once joined, would pass the syntactic check and fail
  # this one.
  defp read_source(root, relative) do
    path = Path.expand(Path.join(root, relative))

    cond do
      not String.starts_with?(path, root <> "/") ->
        {:error, :outside_worktree}

      not File.regular?(path) ->
        {:error, :no_such_file}

      true ->
        case File.stat(path) do
          {:ok, %{size: size}} when size > @max_source_bytes ->
            {:error, {:too_large, size}}

          {:ok, %{size: 0}} ->
            {:error, :empty}

          {:ok, _} ->
            File.read(path)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp stage_source(png, relative, bytes) do
    copy = Path.rootname(png) <> Path.extname(relative)

    with :ok <- File.mkdir_p(Path.dirname(copy)),
         :ok <- File.write(copy, bytes) do
      {:ok, copy}
    end
  end

  defp render(source, png) do
    {w, h} = viewport()

    renderer().render_file(source, png,
      viewport: {w, h},
      full_page: false,
      wait_ms: render_wait_ms()
    )
  end

  # Injectable so the suite can assert the whole seam — the contract
  # checks, the storage layout, the lifetime and the degradation — without
  # a chromium install. The default is the ONE screenshot path the factory
  # already has; this module deliberately does not open a second one.
  defp renderer, do: Application.get_env(:gitf, :inquiry_preview_renderer, GiTF.Visual.Capture)

  defp describe_existing(png, source \\ nil) do
    {w, h} = viewport()

    %{
      png: png,
      source: source || existing_source(png),
      width: w,
      height: h,
      bytes: file_size(png),
      rendered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp existing_source(png) do
    base = Path.rootname(png)
    Enum.find(Enum.map(@source_extensions, &(base <> &1)), &File.regular?/1)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # -- The self-containment contract -------------------------------------------

  # Everything here is a thing a browser would go and FETCH. The renderer
  # is pointed at a file an LLM wrote, running on the box that holds the
  # store, inside the tailnet — so the answer to "may this page reach the
  # network" is a refusal at the seam rather than a sandbox setting we
  # would have to trust chromium to honour.
  #
  # `<iframe>`/`<object>`/`<embed>` are here for a second reason as well:
  # each can point at a local `file:` path and screenshot it, which would
  # turn a mockup into a file-read primitive that renders its output as an
  # image for the operator.
  @forbidden [
    {"://", "an absolute URL (`://`)"},
    {"<link", "a `<link>` — inline your CSS in a `<style>` tag"},
    {"<iframe", "an `<iframe>`"},
    {"<object", "an `<object>`"},
    {"<embed", "an `<embed>`"},
    {"<frame", "a `<frame>`"},
    {"srcdoc", "a `srcdoc` attribute"},
    {"@import", "an `@import`"},
    {"fetch(", "a `fetch(` call"},
    {"xmlhttprequest", "an XMLHttpRequest"},
    {"websocket", "a WebSocket"},
    {"eventsource", "an EventSource"},
    {"sendbeacon", "a sendBeacon call"},
    {"importscripts", "an importScripts call"},
    {"new worker", "a Worker"},
    {"file:", "a `file:` reference"}
  ]

  @protocol_relative ~r/(?:src|href)\s*=\s*["']?\/\//i
  @script_src ~r/<script[^>]*\ssrc\s*=/i

  # Namespace declarations are the one place a URL is legitimate: they are
  # identifiers, never fetched, and a standalone `.svg` is INVALID without
  # one. Stripping them before the scan is what stops the honest thing
  # every design ghost writes from tripping the `://` rule.
  @namespace_decl ~r/xmlns(?::\w+)?\s*=\s*["']https?:\/\/[^"']*["']/i
  @doctype ~r/<!DOCTYPE[^>]*>/i

  @doc """
  `:ok` when `bytes` reaches for nothing outside itself, or `{:error,
  {:not_self_contained, what}}` naming the first thing it reached for.

  Public because it is the contract, and a contract the suite cannot
  assert directly is a contract that drifts from its own documentation.
  """
  @spec self_contained(binary()) :: :ok | {:error, {:not_self_contained, String.t()}}
  def self_contained(bytes) when is_binary(bytes) do
    scanned =
      bytes
      |> String.replace(@namespace_decl, "")
      |> String.replace(@doctype, "")

    lowered = String.downcase(scanned)

    cond do
      found = Enum.find(@forbidden, fn {needle, _} -> String.contains?(lowered, needle) end) ->
        {:error, {:not_self_contained, elem(found, 1)}}

      Regex.match?(@script_src, scanned) ->
        {:error, {:not_self_contained, "a `<script src>` — inline the script instead"}}

      Regex.match?(@protocol_relative, scanned) ->
        {:error, {:not_self_contained, "a protocol-relative `//` URL"}}

      true ->
        :ok
    end
  end

  def self_contained(_), do: {:error, {:not_self_contained, "unreadable content"}}

  @doc "True when `relative` names a file this module is willing to render."
  @spec source_path?(term()) :: boolean()
  def source_path?(relative) when is_binary(relative) do
    trimmed = String.trim(relative)

    trimmed != "" and
      not String.starts_with?(trimmed, "/") and
      not String.starts_with?(trimmed, "~") and
      "" == trimmed |> Path.split() |> Enum.filter(&(&1 == "..")) |> Enum.join() and
      String.downcase(Path.extname(trimmed)) in @source_extensions
  end

  def source_path?(_), do: false

  @doc "Why a syntactically unacceptable mockup reference was dropped."
  @spec source_path_error() :: String.t()
  def source_path_error,
    do:
      "a preview must be a relative .html/.htm/.svg path inside the worktree, " <>
        "with no `..` segments"

  # -- Reading, for the surfaces -----------------------------------------------

  @doc """
  The Catwalk URL for an option's preview, or `nil` when it has none.

  Deliberately a URL and not the bytes: the card is re-rendered on every
  LiveView heartbeat and a filesystem read per option per render would
  charge the questions queue a syscall storm for a picture the browser
  has already cached.
  """
  @spec url(map(), map()) :: String.t() | nil
  def url(inquiry, option) do
    with id when is_binary(id) <- inquiry[:id],
         %{png: png} when is_binary(png) <- option[:preview] do
      "/dashboard/questions/#{id}/preview/#{URI.encode_www_form(to_string(option[:id]))}"
    else
      _ -> nil
    end
  end

  @doc """
  The PNG bytes for `option_id` on `inquiry`, for the controller.

  The path is read off the RECORD, never built from the request: the
  `option_id` in the URL is only ever compared for equality against the
  options the store already holds, so no request can name a file. The
  containment check against `root/0` is the belt to that braces — a
  record written before a root change, or by a future caller, must still
  not be able to serve `/etc/passwd`.
  """
  @spec read(map(), String.t()) :: {:ok, binary()} | {:error, :not_found}
  def read(inquiry, option_id) when is_map(inquiry) and is_binary(option_id) do
    with %{preview: %{png: png}} <-
           Enum.find(inquiry[:options] || [], &(to_string(&1[:id]) == option_id)),
         {:ok, root} <- root(),
         true <- String.starts_with?(Path.expand(png), root <> "/"),
         {:ok, bytes} <- File.read(png) do
      {:ok, bytes}
    else
      _ -> {:error, :not_found}
    end
  end

  def read(_, _), do: {:error, :not_found}

  # -- Retention ---------------------------------------------------------------

  @doc """
  Deletes preview images past their retention window, then oldest-first
  until the tree is inside its byte budget. Returns
  `%{removed: n, freed_bytes: b}`.

  Called from Tachikoma's ~50-minute sweep beside `prune_old_store_data/0`.
  See the moduledoc for the disk reasoning; the one rule worth repeating
  here is that an OPEN inquiry's previews are exempt from both limits,
  because this gate never auto-answers and a question can honestly
  outlive the window while still being the thing a human is about to look
  at.
  """
  @spec prune() :: %{removed: non_neg_integer(), freed_bytes: non_neg_integer()}
  def prune do
    case root() do
      {:ok, root} -> prune_tree(Path.join(root, @subdir))
      _ -> %{removed: 0, freed_bytes: 0}
    end
  rescue
    e ->
      Logger.warning("Inquiry preview prune failed: #{Exception.message(e)}")
      %{removed: 0, freed_bytes: 0}
  end

  defp prune_tree(dir) do
    case protected_paths() do
      :unknown -> %{removed: 0, freed_bytes: 0}
      {:ok, protected} -> prune_tree(dir, protected)
    end
  end

  defp prune_tree(dir, protected) do
    if File.dir?(dir) do
      files =
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.flat_map(&stat_entry/1)
        |> Enum.reject(&MapSet.member?(protected, &1.path))
        |> Enum.sort_by(& &1.mtime, {:asc, NaiveDateTime})

      {aged, rest} = Enum.split_with(files, &older_than_window?/1)
      over_budget = trim_to_budget(rest)

      doomed = aged ++ over_budget
      Enum.each(doomed, &File.rm(&1.path))
      prune_empty_dirs(dir)

      %{removed: length(doomed), freed_bytes: Enum.reduce(doomed, 0, &(&1.size + &2))}
    else
      %{removed: 0, freed_bytes: 0}
    end
  end

  defp stat_entry(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        [%{path: path, size: size, mtime: NaiveDateTime.from_erl!(mtime)}]

      _ ->
        []
    end
  end

  defp older_than_window?(%{mtime: mtime}) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -retention_days() * 86_400, :second)
    NaiveDateTime.compare(mtime, cutoff) == :lt
  end

  # Oldest first until the survivors fit. Age alone does not bound a
  # directory — a burst of previewed questions inside one window is under
  # the age limit and over the disk.
  defp trim_to_budget(files) do
    budget = budget_bytes()
    total = Enum.reduce(files, 0, &(&1.size + &2))

    if total <= budget do
      []
    else
      files
      |> Enum.reduce({total, []}, fn file, {remaining, doomed} ->
        if remaining > budget do
          {remaining - file.size, [file | doomed]}
        else
          {remaining, doomed}
        end
      end)
      |> elem(1)
    end
  end

  # An image a human may be about to look at is not garbage, whatever its
  # mtime says.
  #
  # `:unknown` is not "protect nothing" — it stops the whole sweep. If the
  # store cannot say which questions are open, every file in the tree
  # might belong to one, and a pruner that deletes on an unreadable
  # exclusion list is a pruner that answers questions by removing the
  # pictures. Skipping a sweep costs fifty minutes of disk; getting it
  # wrong costs a decision the operator was about to make.
  defp protected_paths do
    paths =
      GiTF.Inquiry.list_open()
      |> Enum.flat_map(fn inquiry -> inquiry[:options] || [] end)
      |> Enum.flat_map(fn option ->
        case option[:preview] do
          %{png: png} when is_binary(png) ->
            base = Path.rootname(png)
            [png | Enum.map(@source_extensions, &(base <> &1))]

          _ ->
            []
        end
      end)
      |> MapSet.new()

    {:ok, paths}
  rescue
    e ->
      Logger.warning(
        "Inquiry preview prune skipped: could not read open questions " <>
          "(#{Exception.message(e)}) — refusing to prune on an unknown exclusion list"
      )

      :unknown
  end

  defp prune_empty_dirs(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.each(fn dir -> if File.ls(dir) == {:ok, []}, do: File.rmdir(dir) end)
  end

  # -- Paths and configuration -------------------------------------------------

  @doc "The directory previews are stored under, or an error when there is no factory root."
  @spec root() :: {:ok, Path.t()} | {:error, term()}
  def root, do: GiTF.Visual.Capture.screenshots_root()

  @doc "Where `option_id`'s image for `key` on `mission_id` is written."
  @spec png_path(String.t(), String.t(), String.t()) :: Path.t() | nil
  def png_path(mission_id, key, option_id) do
    case root() do
      {:ok, root} ->
        Path.join([
          root,
          @subdir,
          segment(mission_id),
          segment(key),
          segment(option_id) <> ".png"
        ])

      _ ->
        nil
    end
  end

  # Two of these three segments are LLM output. `GiTF.Vault.Path` sanitizes
  # every segment for the same reason and `GiTF.Specs` does not; this
  # module follows the one that does.
  defp segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.trim_leading(".")
    |> String.slice(0, 64)
    |> case do
      "" -> "unnamed"
      cleaned -> cleaned
    end
  end

  @doc """
  Whether previews are wanted (`[:inquiries, :previews_enabled]`, default
  true).

  Read with `get/1` and compared against `false` rather than with
  `get/2`, and that is not a style preference: `Provider.get/2` is
  `get(path) || default`, so a config that says `false` against a `true`
  default reads back as `true`. Every boolean here whose default is true
  has to be written this way or the operator's off switch does nothing.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: ConfigProvider.get([:inquiries, :previews_enabled]) != false

  @doc """
  Whether a mockup would actually render right now.

  Both switches, because inviting a ghost to draw pictures a factory
  cannot render wastes its output and then blames it on the card.
  """
  @spec available?() :: boolean()
  def available?, do: enabled?() and GiTF.Visual.Capture.enabled?()

  @doc "The frame every option is rendered in — identical for all of them, by design."
  @spec viewport() :: {pos_integer(), pos_integer()}
  def viewport do
    {default_w, default_h} = @viewport

    {positive(ConfigProvider.get([:inquiries, :preview_width]), default_w),
     positive(ConfigProvider.get([:inquiries, :preview_height]), default_h)}
  end

  @doc "The largest mockup source this module will read."
  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_bytes

  @doc "How long a preview image survives (`[:inquiries, :preview_retention_days]`)."
  @spec retention_days() :: pos_integer()
  def retention_days,
    do: positive(ConfigProvider.get([:inquiries, :preview_retention_days]), 30)

  @doc "The whole tree's byte ceiling (`[:inquiries, :preview_budget_mb]`)."
  @spec budget_bytes() :: pos_integer()
  def budget_bytes,
    do: positive(ConfigProvider.get([:inquiries, :preview_budget_mb]), 128) * 1024 * 1024

  defp render_wait_ms,
    do: positive(ConfigProvider.get([:inquiries, :preview_wait_ms]), 150)

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp disabled_reason do
    cond do
      not enabled?() -> "previews are off ([:inquiries, :previews_enabled])"
      not GiTF.Visual.Capture.enabled?() -> "visual capture is off (:visual_capture_enabled)"
      true -> "previews are unavailable"
    end
  end

  @doc false
  def describe({:not_self_contained, what}),
    do: "the mockup reaches outside itself — it contains #{what}"

  def describe({:too_large, size}),
    do: "the mockup is #{div(size, 1024)} KB, over the #{div(@max_source_bytes, 1024)} KB limit"

  def describe(:no_worktree), do: "the asking phase has no live worktree to read the mockup from"
  def describe(:no_such_file), do: "no such file in the worktree"
  def describe(:outside_worktree), do: "the path resolves outside the worktree"
  def describe(:empty), do: "the mockup file is empty"
  def describe(:disabled), do: "visual capture is off (:visual_capture_enabled)"
  def describe(:driver_unavailable), do: "no headless browser is installed on this box"
  def describe(:timeout), do: "the renderer timed out"
  def describe(:no_output), do: "the renderer produced no image"
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: "the renderer failed: #{inspect(reason, limit: 5)}"
end
