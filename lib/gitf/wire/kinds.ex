defmodule GiTF.Wire.Kinds do
  @moduledoc """
  The semantic layer of Wire: records ⇄ the JSON-shaped artifact maps the
  factory stores and every downstream consumer already reads.

  Each kind is one `@schema` entry. Its `fields` are the simple records —
  one tag, one JSON key, one type — and are coded generically in both
  directions; only the compound records (a requirement with its criteria,
  an op with its brief) have bespoke clauses. `heads/1`, `tags/1` and
  `reply_tags/1` are all derived from the same table, so adding a field is
  one line here, one line in the card and one row in `specs/WIRE.md`.

  Identifier conventions shared by every kind:

    * `R<n>` ⇄ `"FR-<n>"`, `N<n>` ⇄ `"NFR-<n>"` — requirement ids
    * `F<n>` ⇄ a file path, resolved through the document's file table
      (`GiTF.Wire.Files`) or the enclosing prompt's; a bare path is
      accepted wherever an `F` ref is
    * `C<n>` ⇄ a design component (by name in JSON)
    * `O<n>` ⇄ a planned op (1-based; JSON `depends_on_indices` are 0-based)
    * `-` ⇄ none / null / empty list
  """

  alias GiTF.Wire.Files

  # ---------------------------------------------------------------------------
  # Enum tables. Left = Wire token (what the model writes), right = JSON value.
  # Decoding accepts either side, case-insensitively.
  # ---------------------------------------------------------------------------

  @ears [
    {"ubiq", "ubiquitous"},
    {"event", "event"},
    {"state", "state"},
    {"unwanted", "unwanted"},
    {"opt", "optional"}
  ]
  @priority [{"must", "must-have"}, {"should", "should-have"}, {"could", "nice-to-have"}]
  @severity [{"high", "high"}, {"med", "medium"}, {"low", "low"}]
  @model [{"general", "general"}, {"thinking", "thinking"}, {"fast", "fast"}]
  @complexity Enum.map(~w(trivial simple moderate complex), &{&1, &1})
  @research_cx [{"low", "low"}, {"high", "high"}]
  @verdict [{"pass", "pass"}, {"fail", "fail"}]
  @phases ~w(research requirements design review planning)
  @dims [
    {"out", "final_output"},
    {"traj", "trajectory"},
    {"tool", "tool_usage"},
    {"safe", "safety_alignment"}
  ]

  # ---------------------------------------------------------------------------
  # Schema. `fields`: {tag, json_key, type} for the simple records, in the
  # order the encoder emits them. Types: :text (scalar, "" when absent),
  # :texts (repeated line → list), {:enum, table, default_json_value},
  # :bool (y|n), :atom (a bare token, key omitted when absent). `compound`:
  # head arity of the bespoke records and their property tags. `embed_only`:
  # tags a prompt writes but a reply never does.
  # ---------------------------------------------------------------------------

  @schema %{
    "triage" => %{
      fields: [
        {"cx", "complexity", {:enum, @complexity, nil}},
        {"goal", "goal_restatement", :text},
        {"ext", "external_context", :text},
        {"why", "reasoning", :text}
      ],
      compound: %{"F" => 0, "bug" => 1, "skip" => 1, "files" => 1},
      embed_only: ~w(files)
    },
    "research" => %{
      fields: [
        {"arch", "architecture", :text},
        {"pat", "patterns", :texts},
        {"tech", "tech_stack", :texts},
        {"test", "test_setup", :text},
        {"dep", "dependencies", :texts},
        {"risk", "risks", :texts},
        {"ext", "external_context", :text},
        {"cx", "complexity", {:enum, @research_cx, "low"}},
        {"why", "triage_reasoning", :text}
      ],
      compound: %{"F" => 0, "files" => 1},
      embed_only: ~w(files)
    },
    "requirements" => %{
      fields: [
        {"title", "title", :text},
        {"con", "constraints", :texts},
        {"out", "out_of_scope", :texts}
      ],
      compound: %{"R" => 2, "N" => 1, "ac" => 0},
      embed_only: []
    },
    "design" => %{
      fields: [{"K", "risks", :texts}],
      compound: %{"F" => 0, "C" => 1, "desc" => 0, "if" => 0, "M" => 2, "D" => 2},
      embed_only: []
    },
    "review" => %{
      fields: [
        {"ok", "approved", :bool},
        {"sel", "selected_design", :atom},
        {"risk", "risk_assessment", :text}
      ],
      compound: %{"cov" => 2, "I" => 1, "fix" => 0},
      embed_only: []
    },
    "plan" => %{
      fields: [],
      compound: %{"F" => 0, "O" => 1, "f" => 1, "r" => 1, "dep" => 1, "ac" => 0, "do" => 0},
      embed_only: []
    },
    "validation" => %{
      fields: [
        {"gap", "gaps", :texts},
        {"verdict", "overall_verdict", {:enum, @verdict, "fail"}},
        {"sum", "summary", :text}
      ],
      compound: %{"V" => 2, "rebut" => 0, "unc" => 1},
      embed_only: []
    },
    "scoring" => %{
      fields: [{"sum", "summary", :text}],
      compound: @dims |> Map.new(fn {tag, _} -> {tag, 1} end) |> Map.put("overall", 2),
      embed_only: []
    }
  }

  @kinds Map.keys(@schema)

  @doc "Every artifact kind Wire can encode and decode."
  def kinds, do: @kinds

  @doc "Head arity per tag — what `GiTF.Wire.Syntax` needs to split a line."
  @spec heads(String.t()) :: %{String.t() => non_neg_integer()}
  def heads(kind) do
    case Map.fetch(@schema, kind) do
      {:ok, %{fields: fields, compound: compound}} ->
        Map.merge(Map.new(fields, fn {tag, _, type} -> {tag, field_arity(type)} end), compound)

      :error ->
        %{}
    end
  end

  @doc "Every tag a document of `kind` may carry."
  @spec tags(String.t()) :: [String.t()]
  def tags(kind), do: kind |> heads() |> Map.keys() |> Enum.sort()

  @doc "The tags a model is expected to write — everything but the embed-only ones."
  @spec reply_tags(String.t()) :: [String.t()]
  def reply_tags(kind), do: tags(kind) -- get_in(@schema, [kind, :embed_only])

  defp field_arity(type) when type in [:bool, :atom], do: 1
  defp field_arity({:enum, _, _}), do: 1
  defp field_arity(_), do: 0

  # ===========================================================================
  # DECODE  records → artifact map
  # ===========================================================================

  @doc "Builds the artifact of `kind` from parsed records. `files` is the file table in scope."
  @spec decode(String.t(), [map()], Files.t()) :: map() | list()
  def decode(kind, records, files \\ Files.new())

  def decode("triage", recs, files) do
    files = Files.absorb(files, recs)
    {bug_head, bug_text} = head_text(recs, "bug")
    skip = recs |> head1("skip") |> split_list() |> Enum.map(&String.downcase/1)

    fields("triage", recs)
    |> Map.merge(%{
      "target_files" => file_refs(recs, files),
      "bug_reproducible" => bool(bug_head, true),
      "bug_evidence" => bug_text || "",
      "skip_flags" => Map.new(@phases, fn p -> {"skip_#{p}", p in skip} end)
    })
  end

  # Comprehensive research carries six keys the lightweight form lacks. Any
  # one of them present means the comprehensive shape, with the others
  # defaulted, so the collector's required-key check sees a full record.
  @comprehensive ~w(arch pat tech test dep risk)
  @comprehensive_keys ~w(architecture patterns tech_stack test_setup dependencies risks)

  def decode("research", recs, files) do
    files = Files.absorb(files, recs)
    comprehensive? = Enum.any?(recs, &(&1.tag in @comprehensive))

    fields("research", recs)
    |> Map.put("key_files", file_refs(recs, files))
    |> then(&if(comprehensive?, do: &1, else: Map.drop(&1, @comprehensive_keys)))
  end

  def decode("requirements", recs, _files) do
    frs =
      for r <- tagged(recs, "R") do
        [pattern, priority] = pad(r.head, 2)

        r
        |> requirement("FR", pattern)
        |> Map.put("priority", enum(priority, @priority) || "must-have")
      end

    nfrs = for r <- tagged(recs, "N"), do: requirement(r, "NFR", hd(pad(r.head, 1)))

    fields("requirements", recs)
    |> Map.merge(%{"functional_requirements" => frs, "non_functional" => nfrs})
  end

  def decode("design", recs, files) do
    files = Files.absorb(files, recs)
    comps = tagged(recs, "C")
    names = Map.new(comps, fn c -> {c.id, c.text || "C#{c.id}"} end)
    cname = &resolve_component(&1, names)

    fields("design", recs)
    |> Map.merge(%{
      "components" =>
        for c <- comps do
          %{
            "name" => names[c.id],
            "description" => prop_text(c, "desc") || "",
            "files" => Files.resolve_list(files, hd(pad(c.head, 1))),
            "interfaces" => prop_texts(c, "if")
          }
        end,
      "requirement_mapping" =>
        for m <- tagged(recs, "M") do
          [req, comp] = pad(m.head, 2)
          %{"req_id" => req_id(req), "component" => cname.(comp), "approach" => m.text || ""}
        end,
      "dependencies" =>
        for d <- tagged(recs, "D") do
          [from, to] = pad(d.head, 2)
          %{"from" => cname.(from), "to" => cname.(to)}
        end
    })
  end

  def decode("review", recs, _files) do
    fields("review", recs)
    |> Map.merge(%{
      "coverage" =>
        for c <- tagged(recs, "cov") do
          [req, covered] = pad(c.head, 2)
          %{"req_id" => req_id(req), "covered" => bool(covered, true), "gap" => c.text}
        end,
      "issues" =>
        for i <- tagged(recs, "I") do
          %{
            "severity" => enum(hd(pad(i.head, 1)), @severity) || "medium",
            "description" => i.text || "",
            "suggestion" => prop_text(i, "fix") || ""
          }
        end
    })
  end

  def decode("plan", recs, files) do
    files = Files.absorb(files, recs)

    for o <- tagged(recs, "O") do
      %{
        "title" => o.text || "",
        "description" => prop_text(o, "do") || "",
        "target_files" => Files.resolve_list(files, prop_head1(o, "f")),
        "acceptance_criteria" => prop_texts(o, "ac"),
        "requirement_ids" => o |> prop_head1("r") |> split_list() |> Enum.map(&req_id/1),
        "depends_on_indices" =>
          o |> prop_head1("dep") |> split_list() |> Enum.map(&op_index/1) |> compact(),
        "model_recommendation" => enum(hd(pad(o.head, 1)), @model) || "general"
      }
    end
  end

  def decode("validation", recs, _files) do
    fields("validation", recs)
    |> Map.merge(%{
      "requirements_met" =>
        for v <- tagged(recs, "V") do
          [req, met] = pad(v.head, 2)

          %{"req_id" => req_id(req), "met" => bool(met, false), "evidence" => v.text || ""}
          |> put_present("rebuttal", prop_text(v, "rebut"))
        end,
      "uncovered_requirements" => recs |> head1("unc") |> split_list() |> Enum.map(&req_id/1)
    })
  end

  def decode("scoring", recs, _files) do
    [overall, grade] = pad(head(recs, "overall"), 2)

    dims =
      Map.new(@dims, fn {tag, key} ->
        {head, text} = head_text(recs, tag)
        {key, %{"score" => int(head), "notes" => text || ""}}
      end)

    fields("scoring", recs)
    |> Map.merge(dims)
    |> Map.merge(%{"overall_score" => int(overall), "grade" => grade})
  end

  # -- generic fields -------------------------------------------------------------

  defp fields(kind, recs) do
    for {tag, key, type} <- get_in(@schema, [kind, :fields]),
        value = decode_field(type, recs, tag),
        value != :absent,
        into: %{},
        do: {key, value}
  end

  defp decode_field(:text, recs, tag), do: text(recs, tag) || ""
  defp decode_field(:texts, recs, tag), do: texts(recs, tag)
  defp decode_field(:bool, recs, tag), do: bool(head1(recs, tag), false)
  defp decode_field(:atom, recs, tag), do: head1(recs, tag) || :absent

  defp decode_field({:enum, table, default}, recs, tag),
    do: enum(head1(recs, tag), table) || default

  # -- decode helpers -------------------------------------------------------------

  defp requirement(r, prefix, pattern) do
    description = r.text || ""
    {trigger, response} = split_ears(description)

    %{
      "id" => "#{prefix}-#{r.id}",
      "description" => description,
      "ears_pattern" => enum(pattern, @ears) || "ubiquitous",
      "trigger" => trigger,
      "response" => response,
      "acceptance_criteria" => prop_texts(r, "ac")
    }
  end

  # The EARS trigger/response split is derived, never written: the leading
  # WHEN/WHILE/IF/WHERE clause up to the comma that introduces the
  # "[THEN] <subject> SHALL" clause is the trigger, the rest is the
  # response. Lazy so "IF a repo, author, or PR is …, THEN the system SHALL"
  # splits at the right comma. Downstream consumers only read "description";
  # these two are the additive fields the JSON schema carries.
  @ears_re ~r/^\s*((?:WHEN|WHILE|IF|WHERE)\b.*?),\s*(?:THEN\s+)?((?:\S+\s+){1,4}SHALL\b.*)$/i
  defp split_ears(description) do
    case Regex.run(@ears_re, description) do
      [_, trigger, response] -> {String.trim(trigger), String.trim_trailing(response, ".")}
      nil -> {nil, String.trim_trailing(description, ".")}
    end
  end

  defp tagged(recs, tag), do: Enum.filter(recs, &(&1.tag == tag))
  defp last(recs, tag), do: recs |> tagged(tag) |> List.last()
  defp text(recs, tag), do: with(%{text: t} <- last(recs, tag), do: t, else: (_ -> nil))
  defp texts(recs, tag), do: for(r <- tagged(recs, tag), r.text != nil, do: r.text)
  defp head(recs, tag), do: with(%{head: h} <- last(recs, tag), do: h, else: (_ -> []))
  defp head1(recs, tag), do: recs |> head(tag) |> List.first()
  defp head_text(recs, tag), do: {head1(recs, tag), text(recs, tag)}
  defp prop_text(rec, tag), do: text(rec.props, tag)
  defp prop_texts(rec, tag), do: texts(rec.props, tag)
  defp prop_head1(rec, tag), do: head1(rec.props, tag)

  defp pad(list, n), do: Enum.take(list ++ List.duplicate(nil, n), n)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A kind whose top-level value is "a list of files" (triage target_files,
  # research key_files) takes the `files F1,F3` record when present, else
  # every F declaration in the document, in id order.
  defp file_refs(recs, files) do
    case head1(recs, "files") do
      nil -> Files.declared(recs)
      list -> Files.resolve_list(files, list)
    end
  end

  defp split_list(s), do: Files.split_list(s)

  defp enum(nil, _table), do: nil

  defp enum(token, table) do
    t = String.downcase(token)

    Enum.find_value(table, fn {short, long} ->
      if t in [short, String.downcase(long)], do: long
    end)
  end

  defp enum_token(nil, _table), do: nil

  defp enum_token(value, table) do
    v = value |> to_string() |> String.downcase()

    Enum.find_value(table, fn {short, long} ->
      if v in [short, String.downcase(long)], do: short
    end) || v
  end

  defp bool(nil, default), do: default

  defp bool(token, default) do
    case String.downcase(token) do
      t when t in ~w(y yes true 1 met) -> true
      t when t in ~w(n no false 0 unmet) -> false
      _ -> default
    end
  end

  defp int(nil), do: nil

  defp int(token) do
    case Integer.parse(token) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp req_id(token) do
    cond do
      Regex.match?(~r/^R\d+$/i, token) -> "FR-" <> String.slice(token, 1..-1//1)
      Regex.match?(~r/^N\d+$/i, token) -> "NFR-" <> String.slice(token, 1..-1//1)
      true -> String.upcase(token)
    end
  end

  defp req_token(id) do
    case Regex.run(~r/^(N?)FR-(\d+)$/i, id) do
      [_, "", n] -> "R" <> n
      [_, _, n] -> "N" <> n
      nil -> id
    end
  end

  defp op_index(token) do
    case Regex.run(~r/^O?(\d+)$/i, token) do
      [_, n] -> String.to_integer(n) - 1
      nil -> nil
    end
  end

  defp resolve_component(tok, _names) when tok in [nil, "-"], do: ""

  defp resolve_component(tok, names) do
    case Regex.run(~r/^C(\d+)$/i, tok) do
      [_, n] -> Map.get(names, String.to_integer(n), tok)
      nil -> tok
    end
  end

  # ===========================================================================
  # ENCODE  artifact map → records
  # ===========================================================================

  @doc """
  Renders an artifact of `kind` into records. `files` is the file table the
  enclosing document declares; paths absent from it are added and the grown
  table returned. `opts[:view]` selects a projection.

  Returns `{records, files}`.
  """
  @spec encode(String.t(), map() | list(), Files.t(), keyword()) :: {[map()], Files.t()}
  def encode(kind, artifact, files \\ Files.new(), opts \\ []) do
    {recs, files} = encode_full(kind, artifact, files)
    {project(kind, Keyword.get(opts, :view), recs), files}
  end

  # Views: a phase that needs an artifact's skeleton, not its bulk, asks for
  # `view: :brief` — the same records minus the ones only a full reader acts
  # on. An unknown {kind, view} is a programming error, not a data condition.
  defp project(_kind, nil, recs), do: recs

  defp project("requirements", :brief, recs),
    do: recs |> Enum.reject(&(&1.tag in ~w(con out))) |> Enum.map(&%{&1 | props: []})

  defp project("design", :brief, recs), do: Enum.map(recs, &%{&1 | props: []})

  defp project(kind, view, _recs),
    do: raise(ArgumentError, "Wire kind #{inspect(kind)} has no view #{inspect(view)}")

  defp encode_full("triage", a, files) do
    {files, frefs} = Files.refs(files, a["target_files"] || [])

    skip =
      (a["skip_flags"] || %{})
      |> Enum.filter(fn {_k, v} -> v == true end)
      |> Enum.map(fn {k, _} -> String.replace_prefix(k, "skip_", "") end)
      |> Enum.sort_by(&Enum.find_index(@phases, fn p -> p == &1 end))

    recs =
      field_recs("triage", a, ~w(cx goal ext)) ++
        [
          rec("bug", head: [bool_token(a["bug_reproducible"]) || "-"], text: a["bug_evidence"]),
          rec("skip", head: [list_or_dash(skip)])
        ] ++
        field_recs("triage", a, ~w(why)) ++ [rec("files", head: [list_or_dash(frefs)])]

    {recs, files}
  end

  defp encode_full("research", a, files) do
    {files, frefs} = Files.refs(files, a["key_files"] || [])

    recs =
      field_recs("research", a, ~w(arch)) ++
        [rec("files", head: [list_or_dash(frefs)])] ++
        field_recs("research", a, ~w(pat tech test dep risk ext cx why))

    {recs, files}
  end

  defp encode_full("requirements", a, files) do
    frs =
      (a["functional_requirements"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        rec("R",
          id: req_num(r["id"], i),
          head: [
            enum_token(r["ears_pattern"], @ears) || "ubiq",
            enum_token(r["priority"], @priority) || "must"
          ],
          text: r["description"],
          props: recs("ac", r["acceptance_criteria"])
        )
      end)

    nfrs =
      (a["non_functional"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        rec("N",
          id: req_num(r["id"], i),
          head: [enum_token(r["ears_pattern"], @ears) || "ubiq"],
          text: r["description"],
          props: recs("ac", r["acceptance_criteria"])
        )
      end)

    recs =
      field_recs("requirements", a, ~w(title)) ++
        frs ++ nfrs ++ field_recs("requirements", a, ~w(con out))

    {recs, files}
  end

  defp encode_full("design", a, files) do
    comps = a["components"] || []
    ids = comps |> Enum.with_index(1) |> Map.new(fn {c, i} -> {c["name"], "C#{i}"} end)
    cref = &Map.get(ids, &1, "-")

    {comp_recs, files} =
      comps
      |> Enum.with_index(1)
      |> Enum.map_reduce(files, fn {c, i}, files ->
        {files, frefs} = Files.refs(files, c["files"] || [])

        r =
          rec("C",
            id: i,
            head: [list_or_dash(frefs)],
            text: c["name"],
            props: [maybe_rec("desc", text: c["description"])] ++ recs("if", c["interfaces"])
          )

        {r, files}
      end)

    mapping =
      for m <- a["requirement_mapping"] || [],
          do: rec("M", head: [req_token(m["req_id"]), cref.(m["component"])], text: m["approach"])

    deps =
      for d <- a["dependencies"] || [],
          do: rec("D", head: [cref.(d["from"]), cref.(d["to"])])

    {comp_recs ++ mapping ++ deps ++ field_recs("design", a, ~w(K)), files}
  end

  defp encode_full("review", a, files) do
    coverage =
      for c <- a["coverage"] || [] do
        rec("cov",
          head: [req_token(c["req_id"]), bool_token(c["covered"]) || "-"],
          text: c["gap"]
        )
      end

    issues =
      (a["issues"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {i, n} ->
        rec("I",
          id: n,
          head: [enum_token(i["severity"], @severity) || "med"],
          text: i["description"],
          props: [maybe_rec("fix", text: i["suggestion"])]
        )
      end)

    recs =
      field_recs("review", a, ~w(ok sel)) ++
        coverage ++ issues ++ field_recs("review", a, ~w(risk))

    {recs, files}
  end

  defp encode_full("plan", ops, files) when is_list(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.map_reduce(files, fn {o, i}, files ->
      {files, frefs} = Files.refs(files, o["target_files"] || [])
      deps = Enum.map(o["depends_on_indices"] || [], &"O#{&1 + 1}")
      reqs = Enum.map(o["requirement_ids"] || [], &req_token/1)

      props =
        [
          rec("f", head: [list_or_dash(frefs)]),
          rec("r", head: [list_or_dash(reqs)]),
          maybe_rec("dep", head: [list_or_dash(deps)], skip: deps == [])
        ] ++ recs("ac", o["acceptance_criteria"]) ++ [maybe_rec("do", text: o["description"])]

      r =
        rec("O",
          id: i,
          head: [enum_token(o["model_recommendation"], @model) || "general"],
          text: o["title"],
          props: props
        )

      {r, files}
    end)
  end

  defp encode_full("plan", _, files), do: {[], files}

  defp encode_full("validation", a, files) do
    met =
      for v <- a["requirements_met"] || [] do
        rec("V",
          head: [req_token(v["req_id"]), bool_token(v["met"]) || "-"],
          text: v["evidence"],
          props: [maybe_rec("rebut", text: v["rebuttal"])]
        )
      end

    unc = Enum.map(a["uncovered_requirements"] || [], &req_token/1)

    recs =
      met ++
        [maybe_rec("unc", head: [list_or_dash(unc)], skip: unc == [])] ++
        field_recs("validation", a, ~w(gap verdict sum))

    {compact(recs), files}
  end

  defp encode_full("scoring", a, files) do
    dims =
      for {tag, key} <- @dims do
        d = a[key] || %{}
        rec(tag, head: [to_string(d["score"] || 0)], text: d["notes"])
      end

    overall = rec("overall", head: [to_string(a["overall_score"] || 0), a["grade"] || "-"])
    {dims ++ [overall] ++ field_recs("scoring", a, ~w(sum)), files}
  end

  # -- generic fields -------------------------------------------------------------

  # The simple records of `kind` for the given tags, in that order, absent
  # ones omitted. Enum fields fall back to their default's token.
  defp field_recs(kind, a, tags) do
    by_tag =
      Map.new(get_in(@schema, [kind, :fields]), fn {tag, key, type} -> {tag, {key, type}} end)

    Enum.flat_map(tags, fn tag ->
      {key, type} = Map.fetch!(by_tag, tag)
      encode_field(type, tag, a[key])
    end)
  end

  defp encode_field(:text, tag, value), do: compact([maybe_rec(tag, text: value)])
  defp encode_field(:texts, tag, value), do: recs(tag, value)
  defp encode_field(:bool, tag, value), do: compact([maybe_rec(tag, head: [bool_token(value)])])
  defp encode_field(:atom, tag, value), do: compact([maybe_rec(tag, head: [value])])

  defp encode_field({:enum, table, default}, tag, value),
    do: compact([maybe_rec(tag, head: [enum_token(value, table) || enum_token(default, table)])])

  # -- encode helpers -------------------------------------------------------------

  # One constructor: rec(tag, id: 1, head: [...], text: "...", props: [...]).
  defp rec(tag, fields) do
    %{tag: tag, id: nil, head: [], text: nil, props: []}
    |> Map.merge(Map.new(fields))
    |> Map.update!(:props, &compact/1)
  end

  # A record omitted when it would carry nothing: blank text, a nil head
  # token, or an explicit `skip: true`.
  defp maybe_rec(tag, fields) do
    cond do
      Keyword.get(fields, :skip, false) -> nil
      Keyword.get(fields, :text, :unset) in [nil, ""] -> nil
      nil in Keyword.get(fields, :head, []) -> nil
      true -> rec(tag, Keyword.delete(fields, :skip))
    end
  end

  defp recs(_tag, nil), do: []

  defp recs(tag, list) when is_list(list),
    do: for(item <- list, do: rec(tag, text: stringify(item)))

  defp recs(tag, text) when is_binary(text), do: [rec(tag, text: text)]

  defp stringify(s) when is_binary(s), do: s
  defp stringify(other), do: Jason.encode!(other)

  defp compact(list), do: Enum.reject(list, &is_nil/1)

  defp bool_token(true), do: "y"
  defp bool_token(false), do: "n"
  defp bool_token(_), do: nil

  defp list_or_dash([]), do: "-"
  defp list_or_dash(list), do: Enum.join(list, ",")

  defp req_num(id, fallback) do
    case id && Regex.run(~r/(\d+)$/, id) do
      [_, n] -> String.to_integer(n)
      _ -> fallback
    end
  end
end
