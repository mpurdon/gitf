defmodule GiTF.WireTest do
  # Not async: the PhasePrompts describes flip the global :wire_enabled flag,
  # which other prompt tests read.
  use ExUnit.Case, async: false

  alias GiTF.Major.{PhaseCollector, PhasePrompts}
  alias GiTF.Wire
  alias GiTF.Wire.{Cards, Files, Kinds, Syntax}

  @fixtures Path.expand("../support/fixtures/wire", __DIR__)
  @vectors Path.expand("../../specs/wire/vectors", __DIR__)
  @wire_py Path.expand("../../specs/wire/wire.py", __DIR__)
  @mission %{id: "msn-wire", goal: "Add author grouping", ops: [], pipeline_mode: "full"}

  # Real mission artifacts (msn-ac0539, msn-aa7470), fetched from the box.
  defp fixture(kind),
    do: @fixtures |> Path.join("#{kind}.json") |> File.read!() |> Jason.decode!()

  defp vector(kind, ext), do: File.read!(Path.join(@vectors, "#{kind}.#{ext}"))
  defp vector_json(kind), do: kind |> vector("json") |> Jason.decode!()

  # A standalone document: header, then the file table, then the body —
  # the shape a model reply takes.
  defp standalone(kind, artifact) do
    {text, files} = Wire.encode(kind, artifact)
    [header, body] = String.split(text, "\n", parts: 2)
    header <> "\n" <> Files.render(files) <> body
  end

  defp roundtrip(kind) do
    {:ok, back} = Wire.decode(standalone(kind, fixture(kind)), kind)
    back
  end

  defp full_card(kind), do: Cards.card(kind, contested: true, multi_design: true)

  defp enable_wire(_ctx) do
    Application.put_env(:gitf, :wire_enabled, true)
    on_exit(fn -> Application.delete_env(:gitf, :wire_enabled) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Syntax
  # ---------------------------------------------------------------------------

  describe "Syntax.parse/2" do
    test "records, ids, heads, text and properties" do
      {header, [r]} =
        Syntax.parse(
          """
          %wire 1 plan
          O1 thinking | Add author mode
            f F1,F2
            ac Compiles cleanly
          """,
          Kinds.heads("plan")
        )

      assert header == %{version: 1, kind: "plan"}
      assert %{tag: "O", id: 1, head: ["thinking"], text: "Add author mode"} = r

      assert [%{tag: "f", head: ["F1,F2"], text: nil}, %{tag: "ac", text: "Compiles cleanly"}] =
               r.props
    end

    test "free text keeps a literal ` | ` — the whole point of one text field per line" do
      {_, [r]} = Syntax.parse(~s(M R1 C1 | Append | "author" to the union), Kinds.heads("design"))
      assert r.head == ["R1", "C1"] and r.text == ~s(Append | "author" to the union)
    end

    test "an arity-0 tag and an unknown tag treat ` | ` as literal text" do
      {_, [a]} = Syntax.parse(~s(ac GroupMode is "org" | "repo"), Kinds.heads("plan"))
      assert a.head == [] and a.text == ~s(GroupMode is "org" | "repo")
      {_, [b]} = Syntax.parse("zzz a | b", %{})
      assert b.head == [] and b.text == "a | b"
    end

    test "lenient head: a dropped bar still yields the head tokens" do
      heads = Map.merge(Kinds.heads("triage"), Kinds.heads("review"))
      {_, [a, b]} = Syntax.parse("cx simple\ncov R1 y", heads)
      assert a.head == ["simple"] and a.text == nil
      assert b.head == ["R1", "y"]
    end

    test "continuation lines join with newlines; blank lines become paragraph breaks" do
      {_, [r, _next]} =
        Syntax.parse(
          """
          O1 general | Title
            do First line.
              second line

              new paragraph
          O2 general | Next
          """,
          Kinds.heads("plan")
        )

      assert [%{tag: "do", text: "First line.\nsecond line\n\nnew paragraph"}] = r.props
    end

    test "comments, blank lines, CRLF, tabs and a trailing colon on a tag are tolerated" do
      {_, recs} =
        Syntax.parse(
          "# a comment\r\n\r\nverdict: pass\r\n\tsum done\r\n",
          Kinds.heads("validation")
        )

      assert [%{tag: "verdict", head: ["pass"], props: [%{tag: "sum", text: "done"}]}] = recs
    end

    test "a header is optional" do
      assert {nil, [_]} = Syntax.parse("verdict pass", Kinds.heads("validation"))
    end

    test "render/2 round-trips multi-line text" do
      brief = %{tag: "do", id: nil, head: [], text: "a\nb\n\nc", props: []}
      recs = [%{tag: "O", id: 1, head: ["general"], text: "T", props: [brief]}]

      {_, [back]} =
        Syntax.parse(Syntax.render(%{version: 1, kind: "plan"}, recs), Kinds.heads("plan"))

      assert hd(back.props).text == "a\nb\n\nc"
    end
  end

  # ---------------------------------------------------------------------------
  # Round trips on real mission artifacts
  # ---------------------------------------------------------------------------

  describe "round trip" do
    for kind <- ~w(triage research design review plan scoring) do
      test "#{kind}: encode → decode reproduces the artifact exactly" do
        assert roundtrip(unquote(kind)) == fixture(unquote(kind))
      end
    end

    test "requirements: everything but the derived EARS split survives; the split is literal" do
      original = fixture("requirements")
      back = roundtrip("requirements")
      strip = fn r -> Map.drop(r, ["trigger", "response"]) end

      for key <- ~w(functional_requirements non_functional) do
        assert Enum.map(back[key], strip) == Enum.map(original[key], strip)
      end

      # `inherited_from` is a factory stamp on the stored artifact, not model output.
      keys = ~w(functional_requirements non_functional inherited_from)
      assert Map.drop(back, keys) == Map.drop(original, keys)

      # The derived split lands on the clause boundary, not the first comma.
      fr6 = Enum.find(back["functional_requirements"], &(&1["id"] == "FR-6"))
      assert fr6["trigger"] == "IF a repo, author, or PR is at the unimportant priority level"
      assert fr6["response"] =~ ~r/^the system SHALL suppress/
      fr1 = Enum.find(back["functional_requirements"], &(&1["id"] == "FR-1"))
      assert fr1["trigger"] == nil and fr1["ears_pattern"] == "ubiquitous"
    end

    test "validation: the factory-added requires_approval key is the only difference" do
      back = roundtrip("validation")
      assert back == Map.delete(fixture("validation"), "requires_approval")
      assert Enum.any?(back["requirements_met"], &Map.has_key?(&1, "rebuttal"))
    end

    test "the collector's required keys are all present for every kind" do
      # Comprehensive research carries the four keys the collector wants; a
      # lightweight artifact legitimately lacks architecture/patterns.
      research = %{
        "architecture" => "MVC",
        "key_files" => ["a.ex"],
        "patterns" => ["p"],
        "tech_stack" => ["elixir"],
        "test_setup" => "ExUnit",
        "dependencies" => [],
        "risks" => [],
        "external_context" => "",
        "complexity" => "high",
        "triage_reasoning" => "why"
      }

      assert {:ok, ^research} = Wire.decode(standalone("research", research), "research")

      for kind <- ~w(requirements design review validation) do
        keys = PhaseCollector.required_keys(kind)
        back = roundtrip(kind)
        assert Enum.all?(keys, &Map.has_key?(back, &1)), "#{kind} missing one of #{inspect(keys)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Decoder tolerance — what a fast-tier model actually writes
  # ---------------------------------------------------------------------------

  describe "decode tolerance" do
    test "bare paths are accepted wherever an F ref is, and F refs resolve against the prompt's table" do
      files = Files.from_paths(["src/a.ts", "src/b.ts"])

      doc = """
      %wire 1 plan
      F3 src/new.ts
      O1 general | Title
        f F2,src/literal.ts,F3
        r R1
        ac ok
        do Do it.
      """

      {:ok, [op]} = Wire.decode(doc, "plan", files: files)
      assert op["target_files"] == ["src/b.ts", "src/literal.ts", "src/new.ts"]
      assert op["requirement_ids"] == ["FR-1"] and op["depends_on_indices"] == []
    end

    test "long enum forms, JSON ids, and yes/no booleans are accepted" do
      doc = """
      %wire 1 review
      ok yes
      cov FR-1 true
      cov NFR-2 false | missing
      I1 medium | An issue
        fix Do this
      """

      {:ok, r} = Wire.decode(doc, "review")
      assert r["approved"] == true

      assert [
               %{"req_id" => "FR-1", "covered" => true, "gap" => nil},
               %{"req_id" => "NFR-2", "covered" => false, "gap" => "missing"}
             ] = r["coverage"]

      assert [%{"severity" => "medium", "suggestion" => "Do this"}] = r["issues"]
      refute Map.has_key?(r, "selected_design")
    end

    test "the last ```wire fence wins and prose around it is ignored" do
      text = """
      Thinking aloud:
      ```wire
      verdict fail
      ```
      Final answer:
      ```wire
      %wire 1 validation
      V R1 y | seen
      unc -
      verdict pass
      sum ok
      ```
      Done.
      """

      {:ok, v} = Wire.decode(text, "validation")
      assert v["overall_verdict"] == "pass" and v["uncovered_requirements"] == []
    end

    test "'planning' is an alias of 'plan'; unknown kinds, no wire and empty wire are errors" do
      assert {:ok, [%{"title" => "T", "target_files" => ["src/x.ts"]}]} =
               Wire.decode(
                 "%wire 1 plan\nO1 general | T\n  f src/x.ts\n  r R1\n  do x",
                 "planning"
               )

      assert {:error, :unknown_kind} = Wire.decode("%wire 1 x\nfoo", "simplify")
      assert {:error, :no_wire_found} = Wire.decode(~s({"approved": true}), "review")
      assert {:error, :empty_wire} = Wire.decode("```wire\n# nothing\n```", "review")
    end

    test "triage skip list maps to the five skip flags; F declarations are the target files" do
      {:ok, t} =
        Wire.decode(
          "%wire 1 triage\ncx simple\nskip research,design\nbug y | seen\nF1 a.ex",
          "triage"
        )

      assert t["skip_flags"] == %{
               "skip_research" => true,
               "skip_requirements" => false,
               "skip_design" => true,
               "skip_review" => false,
               "skip_planning" => false
             }

      assert t["target_files"] == ["a.ex"] and t["complexity"] == "simple"
    end

    test "dependencies accept bare numbers as well as O ids" do
      {:ok, [_, b]} =
        Wire.decode(
          "%wire 1 plan\nO1 general | A\n  do a\nO2 general | B\n  dep 1,O1\n  do b",
          "plan"
        )

      assert b["depends_on_indices"] == [0, 0]
    end
  end

  # ---------------------------------------------------------------------------
  # Views
  # ---------------------------------------------------------------------------

  describe "views" do
    test "requirements brief keeps R/N lines and drops criteria, constraints and scope" do
      {text, _} = Wire.encode("requirements", fixture("requirements"), Files.new(), view: :brief)
      assert text =~ ~r/^R13 ubiq must \| /m and text =~ ~r/^N3 ubiq \| /m
      refute text =~ ~r/^  ac /m or text =~ ~r/^(con|out) /m
      {:ok, back} = Wire.decode(text, "requirements")
      assert length(back["functional_requirements"]) == 13
    end

    test "design brief keeps components, mapping, dependencies and risks without descriptions" do
      {text, _} = Wire.encode("design", fixture("design"), Files.new(), view: :brief)
      assert text =~ ~r/^C3 F1,F2 \| Group header priority badge$/m
      assert text =~ ~r/^M R9 C2 \| /m and text =~ ~r/^D C1 C3$/m and text =~ ~r/^K /m
      refute text =~ ~r/^  (desc|if) /m
    end

    test "an unknown view is a programming error" do
      assert_raise ArgumentError, ~r/no view :tiny/, fn ->
        Wire.encode("plan", fixture("plan"), Files.new(), view: :tiny)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Cards and schema stay in step
  # ---------------------------------------------------------------------------

  describe "cards" do
    test "every reply tag of every kind appears in that kind's card, and every card decodes" do
      for kind <- Wire.kinds() do
        card = full_card(kind)

        for tag <- Kinds.reply_tags(kind) do
          assert Regex.match?(~r/^\s*#{Regex.escape(tag)}\d*\b/m, card),
                 "#{kind} card lacks tag #{tag}"
        end

        assert {:ok, artifact} = Wire.decode(card, kind), "#{kind} card does not decode"
        refute artifact in [%{}, []]
      end
    end

    test "cards carry no trailing parenthetical annotations on value lines" do
      for kind <- Wire.kinds() do
        {:ok, body} = Wire.extract(full_card(kind))

        for line <- String.split(body, "\n"), not String.starts_with?(line, "#") do
          refute line =~ ~r/\s\([^)]*\)\s*$/, "#{kind}: annotation on a value line: #{line}"
        end
      end
    end

    test "the validation card carries the rebut contract only when contested" do
      assert Cards.card("validation", contested: true) =~ "`rebut` is a SEPARATE property line"
      refute Cards.card("validation") =~ "rebut"
    end

    test "the grammar card names the four rules a decoder needs" do
      g = Cards.grammar()
      assert g =~ "Column 0" and g =~ "Two-space" and g =~ "Four-space" and g =~ ~s(" | ")
    end
  end

  # ---------------------------------------------------------------------------
  # Documents (prompt side) and the file-table round trip
  # ---------------------------------------------------------------------------

  describe "document/2 and files_in/1" do
    test "shares one headed file table across artifacts, puts it first, reports absent ones" do
      {doc, files, absent} =
        Wire.document([
          {"Technical Design", "design", fixture("design")},
          {"Planned Ops", "plan", fixture("plan")},
          {"Review", "review", nil}
        ])

      assert String.starts_with?(
               doc,
               "## Files\n\n```wire\n%wire 1 files\nF1 src/windows/MainApp.tsx\nF2 src/windows/MainApp.css\n```"
             )

      assert map_size(files) == 2 and absent == ["Review"]
      assert doc =~ "## Technical Design\n\n```wire\n%wire 1 design\n"
      # Declarations live only in the Files block; artifact blocks cite.
      refute doc |> String.replace(~r/## Files.*?```\n/s, "") |> String.match?(~r/^F\d+ /m)
      assert Files.resolve(Wire.files_in(doc), "F2") == "src/windows/MainApp.css"
    end

    test "files_in/1 ignores the example F lines of an output card" do
      {doc, _, _} = Wire.document([{"D", "design", fixture("design")}])
      prompt = doc <> Wire.output_format("plan")
      assert Files.resolve(Wire.files_in(prompt), "F1") == "src/windows/MainApp.tsx"
    end
  end

  # ---------------------------------------------------------------------------
  # The reference decoder outside the factory agrees with this one
  # ---------------------------------------------------------------------------

  describe "specs/wire/vectors" do
    test "the Elixir decoder reproduces every vector" do
      for kind <- Wire.kinds() do
        expected = vector_json(kind)

        assert {:ok, ^expected} = Wire.decode(vector(kind, "wire"), kind),
               "vector #{kind} drifted"
      end
    end

    test "the vectors are the fixtures round-tripped (regenerate when the encoder changes)" do
      for kind <- Wire.kinds() do
        assert standalone(kind, fixture(kind)) == vector(kind, "wire"),
               "vector #{kind}.wire is stale"
      end
    end

    @tag :python
    test "the Python reference decoder agrees on every vector" do
      case System.find_executable("python3") do
        nil ->
          IO.puts("python3 not found — skipping reference-decoder check")

        python ->
          decode = fn args ->
            {out, 0} = System.cmd(python, [@wire_py | args])
            Jason.decode!(out)
          end

          for kind <- Wire.kinds() do
            assert decode.([kind, Path.join(@vectors, "#{kind}.wire")]) == vector_json(kind),
                   "python decoder disagrees on #{kind}"
          end

          context = Path.join(@vectors, "context.prompt.md")
          reply = Path.join(@vectors, "context.reply.wire")
          assert decode.(["plan", "--files", context, reply]) == vector_json("context.reply")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: collector and prompts
  # ---------------------------------------------------------------------------

  describe "PhaseCollector.extract_structured/3" do
    test "reads a Wire reply against the prompt's file table, JSON otherwise" do
      {prompt, _, _} = Wire.document([{"D", "design", fixture("design")}])
      wire = "```wire\n%wire 1 plan\nO1 general | T\n  f F1\n  r R1\n  do d\n```"

      assert {:ok, [%{"target_files" => ["src/windows/MainApp.tsx"]}]} =
               PhaseCollector.extract_structured("planning", wire, prompt: prompt)

      json = ~s(```json\n[{"title": "T"}]\n```)
      assert {:ok, [%{"title" => "T"}]} = PhaseCollector.extract_structured("planning", json)
    end

    test "falls back to JSON when the wire fence is empty" do
      text = "```wire\n\n```\n```json\n{\"approved\": true}\n```"
      assert {:ok, %{"approved" => true}} = PhaseCollector.extract_structured("review", text)
    end
  end

  describe "PhasePrompts in JSON mode" do
    test "honours the brief view for scoring" do
      prompt =
        PhasePrompts.scoring_prompt(@mission, fixture("requirements"), fixture("validation"))

      assert prompt =~ "functional_requirements"
      refute prompt =~ "acceptance_criteria"
    end
  end

  describe "PhasePrompts with :wire_enabled" do
    setup :enable_wire

    test "embeds artifacts as Wire and asks for a Wire reply" do
      prompt =
        PhasePrompts.planning_prompt(
          @mission,
          fixture("design"),
          fixture("requirements"),
          fixture("review")
        )

      assert prompt =~ "## Files\n\n```wire\n%wire 1 files\nF1 src/windows/MainApp.tsx"
      for kind <- ~w(requirements design review plan), do: assert(prompt =~ "%wire 1 #{kind}")
      assert prompt =~ "Output ONLY a Wire document" and prompt =~ "Tag each op with `r`"
      refute prompt =~ "```json"
    end

    test "validation shows the rebut line and contract only when contested" do
      plain = PhasePrompts.validation_prompt(@mission, fixture("requirements"), fixture("plan"))
      refute plain =~ ~r/^\s*rebut /m
      assert plain =~ "it in `gap`" and plain =~ "Set `verdict` to `fail`"

      contested =
        PhasePrompts.validation_prompt(@mission, fixture("requirements"), fixture("plan"), "",
          contested_requirements: [%{"req_id" => "FR-5", "reason" => "unmet: x"}]
        )

      assert contested =~ ~r/^\s*rebut /m and contested =~ "`rebut` is a SEPARATE property line"
    end

    test "review shows sel only for multi-design and embeds variants as brief views" do
      single =
        PhasePrompts.review_prompt(
          @mission,
          %{"normal" => fixture("design")},
          fixture("requirements"),
          fixture("research")
        )

      refute single =~ ~r/^sel /m
      assert single =~ ~r/^  desc /m

      multi =
        PhasePrompts.review_prompt(
          @mission,
          %{"minimal" => fixture("design"), "normal" => fixture("design")},
          fixture("requirements"),
          fixture("research")
        )

      assert multi =~ ~r/^sel minimal\|normal\|complex/m and multi =~ "## Design: MINIMAL"
      refute multi =~ ~r/^  desc /m
    end

    test "scoring embeds the brief requirements view" do
      prompt =
        PhasePrompts.scoring_prompt(@mission, fixture("requirements"), fixture("validation"))

      assert prompt =~ ~r/^R1 ubiq must \| /m
      refute prompt =~ ~r/^  ac /m
    end

    test "a skipped phase's artifact is named as absent, not rendered as {}" do
      prompt = PhasePrompts.design_prompt(@mission, fixture("requirements"), nil)
      assert prompt =~ "## Codebase Research\n\n_(not produced — phase skipped)_"
    end

    test "the prompt's file table round-trips through files_in/1 for the reply" do
      files =
        @mission
        |> PhasePrompts.validation_prompt(fixture("requirements"), fixture("plan"))
        |> Wire.files_in()

      assert Files.resolve(files, "F1") == "src/windows/MainApp.tsx"
      assert Files.resolve(files, "F2") == "src/windows/MainApp.css"
    end

    test "the partial planning prompt speaks Wire too" do
      prompt =
        PhasePrompts.partial_planning_prompt(
          @mission,
          [{"Requirements", "requirements", fixture("requirements")}, {"Design", "design", nil}],
          sector_path: "/x"
        )

      assert prompt =~ "%wire 1 requirements" and prompt =~ "%wire 1 plan"
      refute prompt =~ "## Design"
    end
  end
end
