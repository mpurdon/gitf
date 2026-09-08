defmodule GiTF.Wire do
  @moduledoc """
  Wire — the compact notation phase ghosts read and write instead of JSON.

  Every artifact the Major pipeline passes between phases (triage, research,
  requirements, design, review, plan, validation, scoring) is a JSON-shaped
  map internally and stays one: Wire is a **codec**, not a storage format.
  Prompts embed prior artifacts as Wire (`encode/4`, `document/2`) and ask
  for Wire replies (`GiTF.Wire.Cards.output_format/2`); the collector decodes
  a Wire reply into the same map a JSON reply would have produced
  (`decode/3`). Nothing downstream of the collector knows Wire exists.

  Why it is cheaper, in order of effect:

    1. **No scaffolding.** JSON spends a token on every quote, brace, colon
       and comma and repeats every key per array element. Wire spends the
       tag once per line.
    2. **Reference, don't repeat.** Paths, requirement ids and component
       names are declared once and cited by id (`F3`, `R7`, `C2`).
    3. **Derive, don't duplicate.** An EARS requirement's `trigger` and
       `response` are derived from its sentence, not written a second and
       third time.
    4. **Output is the expensive direction** (5× input) and every one of
       the above applies to what the model writes.

  What it deliberately keeps: the prose. Acceptance criteria, evidence, op
  briefs and risks stay full natural-language sentences — the notation
  removes punctuation scaffolding, never meaning. That is the basis for the
  equal-success-rate claim, alongside a decoder that accepts JSON too, so
  a model that ignores the card still lands.

  The normative grammar, per-kind tables and a reference decoder for
  systems outside the factory live in `specs/WIRE.md` and `specs/wire/`.

  Gated by the `:wire_enabled` flag (`GITF_WIRE_ENABLED`, default off) on
  the *prompt* side only; decoding is always on.
  """

  alias GiTF.Wire.{Cards, Files, Kinds, Syntax}

  @version 1
  @fence_re ~r/```wire\s*\n([\s\S]*?)\n\s*```/

  @doc "Whether prompts are built in Wire. Decoding does not consult this."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :wire_enabled, false) == true

  @doc "The artifact kinds Wire speaks. `planning` is accepted as an alias of `plan`."
  def kinds, do: Kinds.kinds()

  @doc false
  def normalize_kind("planning"), do: "plan"
  def normalize_kind(kind) when is_binary(kind), do: kind
  def normalize_kind(kind) when is_atom(kind), do: kind |> Atom.to_string() |> normalize_kind()

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  @doc """
  Encodes one artifact as a Wire block (no fence, no file table).

  Returns `{text, files}` — the file table grown by any paths the artifact
  cites, which the caller renders once via `document/2`. `opts[:view]`
  selects a projection (`:brief`).
  """
  @spec encode(String.t(), map() | list(), Files.t(), keyword()) :: {String.t(), Files.t()}
  def encode(kind, artifact, files \\ Files.new(), opts \\ []) do
    kind = normalize_kind(kind)
    {records, files} = Kinds.encode(kind, artifact || %{}, files, opts)
    {Syntax.render(%{version: @version, kind: kind}, records), files}
  end

  @doc """
  Builds the artifact section of a prompt from several artifacts, sharing
  one file table across them.

  `sections` is a list of `{heading, kind, artifact}` or
  `{heading, kind, artifact, opts}`. Returns `{markdown, files, absent}`:
  a `## Files` table (when any file is cited) followed by one fenced Wire
  block per present artifact under its heading, and the headings of the
  artifacts that were nil or empty, for the caller to render as it sees
  fit. The file table comes first so every `F<n>` a block cites has already
  been seen, and carries its own `%wire 1 files` header so `files_in/1` can
  find it again among the other fences of a stored prompt.
  """
  @type section ::
          {String.t(), String.t(), map() | list() | nil}
          | {String.t(), String.t(), map() | list() | nil, keyword()}
  @spec document([section()], Files.t()) :: {String.t(), Files.t(), [String.t()]}
  def document(sections, files \\ Files.new()) do
    sections =
      Enum.map(sections, fn
        {h, k, a} -> {h, k, a, []}
        four -> four
      end)

    {present, absent} =
      Enum.split_with(sections, fn {_h, _k, a, _o} -> a not in [nil, %{}, []] end)

    {blocks, files} =
      Enum.map_reduce(present, files, fn {heading, kind, artifact, opts}, files ->
        {text, files} = encode(kind, artifact, files, opts)
        {"## #{heading}\n\n```wire\n#{text}```\n", files}
      end)

    table =
      case Files.render(files) do
        "" -> ""
        table -> "## Files\n\n```wire\n%wire #{@version} files\n#{table}```\n\n"
      end

    {table <> Enum.join(blocks, "\n"), files, Enum.map(absent, &elem(&1, 0))}
  end

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  @doc """
  Decodes a Wire reply for `kind` into the artifact map.

  `text` may be a bare Wire document or any text containing a ```wire
  fence (the last fence wins — models sometimes think aloud in an earlier
  one). `opts[:files]` is the file table the prompt declared, so replies
  can cite `F<n>` without redeclaring.

  Returns `{:ok, artifact}` or `{:error, :no_wire_found | :empty_wire |
  :unknown_kind}`. Decoding is lenient by design (see `GiTF.Wire.Syntax`);
  those three are the only failures.
  """
  @spec decode(String.t(), String.t(), keyword()) :: {:ok, map() | list()} | {:error, term()}
  def decode(text, kind, opts \\ []) when is_binary(text) do
    kind = normalize_kind(kind)

    with true <- kind in kinds() || {:error, :unknown_kind},
         {:ok, body} <- extract(text),
         {_header, [_ | _] = records} <- Syntax.parse(body, Kinds.heads(kind)) do
      {:ok, Kinds.decode(kind, records, Keyword.get(opts, :files, Files.new()))}
    else
      {_header, []} -> {:error, :empty_wire}
      error -> error
    end
  end

  @doc """
  Finds the Wire body in `text`: the last ```wire fence, or the text itself
  when it starts with a `%wire` header.
  """
  @spec extract(String.t()) :: {:ok, String.t()} | {:error, :no_wire_found}
  def extract(text) do
    case Regex.scan(@fence_re, text) do
      [] ->
        trimmed = String.trim(text)

        if String.starts_with?(trimmed, "%wire"),
          do: {:ok, trimmed},
          else: {:error, :no_wire_found}

      matches ->
        [_, body] = List.last(matches)
        {:ok, body}
    end
  end

  @doc """
  Recovers the file table a prompt declared, so a reply can be decoded
  against it. Only the fence headed `%wire 1 files` counts — a prompt also
  carries artifact blocks and the output card, whose example `F` lines must
  not shadow the real table. The prompt is stored verbatim as the phase
  op's description, which makes this a stateless round trip.
  """
  @spec files_in(String.t() | nil) :: Files.t()
  def files_in(nil), do: Files.new()

  def files_in(prompt) when is_binary(prompt) do
    @fence_re
    |> Regex.scan(prompt)
    |> Enum.map(fn [_, body] -> Syntax.parse(body) end)
    |> Enum.filter(&match?({%{kind: "files"}, _}, &1))
    |> Enum.reduce(Files.new(), fn {_header, records}, files -> Files.absorb(files, records) end)
  end

  # ---------------------------------------------------------------------------
  # Prompt text
  # ---------------------------------------------------------------------------

  defdelegate output_format(kind, opts \\ []), to: Cards
end
