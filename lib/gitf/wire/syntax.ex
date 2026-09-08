defmodule GiTF.Wire.Syntax do
  @moduledoc """
  The kind-independent layer of Wire: text ⇄ records.

  A Wire document is a list of lines. Every non-blank, non-comment line is a
  **record** or a **property** of the record above it:

      TAG[n] [head tokens] [| text]      column 0 — a record
        tag  [head tokens] [| text]      1–3 spaces — a property of the record above
          more text                      4+ spaces — continues the previous text

  The head is a run of space-separated atoms (enums, refs, `y`/`n`, numbers,
  `-`). The text is everything after the first ` | ` up to the end of the
  line and may contain any character — pipes included. That is the whole
  trick: exactly one free-text field per line, always last, so the grammar
  needs no escaping at all.

  Whether a tag carries a head is declared by the kind's schema
  (`GiTF.Wire.Kinds`) and handed in as `heads`, a map of tag → head arity.
  A tag with arity 0 — or any tag the schema does not list — takes
  everything after it as text and needs no ` | `.

  This module knows nothing about phases or JSON. See `GiTF.Wire` for the
  public API and `specs/WIRE.md` for the normative grammar.
  """

  @type rec :: %{
          tag: String.t(),
          id: pos_integer() | nil,
          head: [String.t()],
          text: String.t() | nil,
          props: [rec()]
        }

  @type heads :: %{optional(String.t()) => non_neg_integer()}

  @header_re ~r/^%wire\s+(\d+)(?:\s+([a-z_]+))?\s*$/
  @record_re ~r/^([A-Za-z][A-Za-z_]*?)(\d+)?:?(?:\s+(.*))?$/

  @doc """
  Parses Wire text into `{header, records}`.

  `header` is `%{version: 1, kind: "plan"}` (kind may be nil) or nil when
  the document has no `%wire` line. Never raises: a line that fits no rule
  is skipped.
  """
  @spec parse(String.t(), heads()) :: {map() | nil, [rec()]}
  def parse(text, heads \\ %{}) when is_binary(text) do
    # Accumulator: {header, records (reversed, props reversed), blank?} —
    # blank? remembers that the previous line was empty so the next
    # continuation line re-inserts it as a paragraph break.
    {header, records, _blank?} =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.reduce({nil, [], false}, fn line, acc -> classify(line, acc, heads) end)

    {header, records |> Enum.reverse() |> Enum.map(&%{&1 | props: Enum.reverse(&1.props)})}
  end

  # -- line classification ------------------------------------------------------

  defp classify(line, {header, acc, blank?}, heads) do
    trimmed = String.trim(line)
    indent = indent(line)

    cond do
      trimmed == "" ->
        {header, acc, true}

      indent == 0 and String.starts_with?(trimmed, "#") ->
        {header, acc, false}

      header == nil and acc == [] and Regex.match?(@header_re, line) ->
        [_, version | rest] = Regex.run(@header_re, line)
        {%{version: String.to_integer(version), kind: List.first(rest)}, acc, false}

      indent == 0 ->
        {header, push(acc, record(trimmed, heads)), false}

      indent in 1..3 and acc != [] ->
        [parent | rest] = acc
        {header, [%{parent | props: push(parent.props, record(trimmed, heads))} | rest], false}

      indent >= 4 and acc != [] ->
        {header, continue(acc, trimmed, blank?), false}

      true ->
        {header, acc, false}
    end
  end

  defp push(acc, nil), do: acc
  defp push(acc, rec), do: [rec | acc]

  # A leading tab reads as a property indent, never as a continuation.
  defp indent(line) do
    line = String.replace_prefix(line, "\t", "  ")
    byte_size(line) - byte_size(String.trim_leading(line, " "))
  end

  defp record(line, heads) do
    case Regex.run(@record_re, line) do
      [_, tag] -> new(tag, nil, [], nil)
      [_, tag, num] -> new(tag, id(num), [], nil)
      [_, tag, num, rest] -> new(tag, id(num), rest, Map.get(heads, tag, 0))
      nil -> nil
    end
  end

  defp new(tag, id, rest, arity) when is_binary(rest) do
    {head, text} = split_head(rest, arity)
    new(tag, id, head, text)
  end

  defp new(tag, id, head, text), do: %{tag: tag, id: id, head: head, text: text, props: []}

  defp id(""), do: nil
  defp id(num), do: String.to_integer(num)

  # Split "head tokens | text" by the tag's declared head arity.
  #
  #   arity 0      → no head; the whole rest is text (a ` | ` is literal)
  #   arity k > 0  → head is everything before the first ` | `; if the line
  #                  has no ` | `, the first k whitespace-separated tokens are
  #                  the head and any remainder is text (lenient form)
  defp split_head(rest, 0), do: {[], blank_to_nil(rest)}

  defp split_head(rest, k) do
    case String.split(rest, " | ", parts: 2) do
      [head, text] ->
        {tokens(head), blank_to_nil(text)}

      [only] ->
        # Models sometimes drop the bar: "cx simple", "cov R1 y".
        {head, text} = only |> tokens() |> Enum.split(k)
        {head, text |> Enum.join(" ") |> blank_to_nil()}
    end
  end

  defp tokens(s), do: String.split(s, ~r/\s+/, trim: true)

  defp blank_to_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  # -- continuation text ----------------------------------------------------------

  # Appends a continuation line to the open text — the last property's if
  # the record has any, else the record's own.
  defp continue([rec | rest], line, blank?) do
    sep = if blank?, do: "\n\n", else: "\n"

    rec =
      case rec.props do
        [] -> %{rec | text: join(rec.text, sep, line)}
        [prop | props] -> %{rec | props: [%{prop | text: join(prop.text, sep, line)} | props]}
      end

    [rec | rest]
  end

  defp join(nil, _sep, line), do: line
  defp join(text, sep, line), do: text <> sep <> line

  # -- rendering ------------------------------------------------------------------

  @doc """
  Renders records back to Wire text. `header` may be nil.

  Text containing newlines is emitted with the first line inline and the
  rest as 4-space continuation lines; blank lines inside the text survive as
  paragraph breaks.
  """
  @spec render(map() | nil, [rec()]) :: String.t()
  def render(header, records) do
    head_line =
      case header do
        %{version: v, kind: k} when is_binary(k) -> ["%wire #{v} #{k}"]
        %{version: v} -> ["%wire #{v}"]
        nil -> []
      end

    Enum.join(head_line ++ Enum.flat_map(records, &render_record(&1, "")), "\n") <> "\n"
  end

  defp render_record(rec, indent) do
    id = if rec.id, do: Integer.to_string(rec.id), else: ""
    head = Enum.join(rec.head, " ")
    [first | continuation] = String.split(rec.text || "", "\n")

    line =
      case {head, rec.text} do
        {"", nil} -> "#{indent}#{rec.tag}#{id}"
        {"", _} -> "#{indent}#{rec.tag}#{id} #{first}"
        {head, nil} -> "#{indent}#{rec.tag}#{id} #{head}"
        {head, _} -> "#{indent}#{rec.tag}#{id} #{head} | #{first}"
      end

    [line] ++
      Enum.map(continuation, &if(&1 == "", do: "", else: "    " <> &1)) ++
      Enum.flat_map(rec.props, &render_record(&1, "  "))
  end
end
