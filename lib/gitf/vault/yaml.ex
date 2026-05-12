defmodule GiTF.Vault.YAML do
  @moduledoc """
  Tiny YAML emission helpers for vault frontmatter and inline scalars.

  We don't need a full YAML serializer — every vault document either
  uses a flat scalar frontmatter or a structured block we control. This
  module gives the four renderer modules and `GiTF.Workflow.serialize/1`
  a single place to format strings, render frontmatter, and emit lists
  consistently. Three near-duplicate `quote_str/1` and `iso/1`
  implementations were folded in here.
  """

  @doc """
  Wraps a binary in double quotes, escaping `"` and collapsing newlines
  to spaces. Atoms are stringified first. `nil` returns the literal
  `"null"` so it round-trips through `Enum.reject(... in [nil, "null"])`
  predicates the renderers use.
  """
  @spec quote_str(any()) :: String.t()
  def quote_str(nil), do: "null"
  def quote_str(v) when is_atom(v), do: quote_str(Atom.to_string(v))

  def quote_str(v) when is_binary(v) do
    escaped = v |> String.replace("\"", "\\\"") |> String.replace("\n", " ")
    "\"#{escaped}\""
  end

  def quote_str(v), do: quote_str(to_string(v))

  @doc """
  Formats a `DateTime` (or pre-stringified ISO8601 binary) for
  frontmatter. Returns the literal `"null"` for unknown values so the
  renderer's `Enum.reject` filter drops the field cleanly.
  """
  @spec iso(any()) :: String.t()
  def iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso(s) when is_binary(s), do: s
  def iso(_), do: "null"

  @doc """
  Formats a number as a fixed-2-decimal string. Pass-through for
  integers/strings; nil → `"null"`.
  """
  @spec format_float(any()) :: String.t()
  def format_float(nil), do: "null"
  def format_float(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  def format_float(n), do: to_string(n)

  @doc """
  Renders a list of `{key, value}` pairs as a YAML frontmatter block.

  - Drops pairs whose value is `nil` or `"null"`.
  - Emits each kept pair as `key: value`.
  - Wraps the result in `---\n…\n---`.

  Values are emitted as-is — the caller is responsible for quoting
  scalars via `quote_str/1` first.
  """
  @spec frontmatter([{String.t(), any()}]) :: String.t()
  def frontmatter(fields) when is_list(fields) do
    body =
      fields
      |> Enum.reject(fn {_k, v} -> v in [nil, "null"] end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")

    "---\n" <> body <> "\n---"
  end
end
