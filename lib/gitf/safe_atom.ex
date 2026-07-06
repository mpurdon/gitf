defmodule GiTF.SafeAtom do
  @moduledoc """
  Bounded interning of *externally-derived* strings into atoms.

  The BEAM's atom table is not garbage-collected and is capped (~1M by
  default); `String.to_atom/1` on attacker- or LLM-controlled input (MCP tool
  schemas, model output, decoded API bodies) is a classic node-crash DoS. This
  module makes that conversion safe:

    1. Prefer an atom that already exists (`to_existing_atom`) — free, unbounded.
    2. Only mint a NEW atom if the string is a short, identifier-shaped token
       AND a process-wide budget of dynamically-created atoms is not exhausted.
       The budget is tracked in a lock-free `:atomics` counter, so this is safe
       to call from any process with no serialization.
    3. Otherwise return `:error` and let the caller keep the string.

  This bounds the blast radius of hostile input to `@max_dynamic_atoms` new
  atoms total, regardless of how many distinct strings arrive.
  """

  @max_dynamic_atoms 8_192
  @max_len 64
  @counter_key {__MODULE__, :counter}
  @identifier ~r/^[a-zA-Z_][a-zA-Z0-9_.]*$/

  @doc """
  Interns `string` to an atom safely. Returns `{:ok, atom}` or `:error`.
  """
  @spec intern(term()) :: {:ok, atom()} | :error
  def intern(atom) when is_atom(atom), do: {:ok, atom}

  def intern(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> maybe_create(string)
  end

  def intern(_), do: :error

  @doc """
  Interns `string`, falling back to `default` (or the original string) when it
  cannot be safely interned.
  """
  @spec intern!(term(), term()) :: atom() | binary()
  def intern!(string, default \\ nil) do
    case intern(string) do
      {:ok, atom} -> atom
      :error -> default || string
    end
  end

  @doc "How many dynamic atoms this node has minted via `intern/1` (approximate)."
  @spec minted() :: non_neg_integer()
  def minted, do: :atomics.get(counter(), 1)

  # -- Internals -------------------------------------------------------------

  defp maybe_create(string) do
    if identifier?(string) and bump_if_under_cap() do
      {:ok, String.to_atom(string)}
    else
      :error
    end
  end

  defp identifier?(string) do
    byte_size(string) <= @max_len and Regex.match?(@identifier, string)
  end

  # Atomically increment the mint counter; return false (and undo) if it would
  # exceed the cap. add_get is a single atomic op — no lock, no race.
  defp bump_if_under_cap do
    ref = counter()

    if :atomics.add_get(ref, 1, 1) <= @max_dynamic_atoms do
      true
    else
      :atomics.sub(ref, 1, 1)
      false
    end
  end

  defp counter do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
