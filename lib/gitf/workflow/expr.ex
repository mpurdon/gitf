defmodule GiTF.Workflow.Expr do
  @moduledoc """
  Tiny, safe boolean expression evaluator for workflow conditional
  transitions and gates.

  Used by conditional `next:` rules to decide which phase to advance to
  based on the just-completed phase's artifact and the mission record:

      artifact.bug_reproducible == false
      artifact.skip_flags.research == true
      mission.review_plan == true and artifact.complexity in ["minimal", "normal"]
      not artifact.needs_followup

  ## Grammar (a strict subset of Elixir)

    * **Variables** — only `artifact` and `mission`. Dotted access reads
      nested maps, trying the atom key then the string key, so artifacts
      that come back from JSON with string keys Just Work:
      `artifact.skip_flags.research` → `m["skip_flags"]["research"]`.
      A missing key is `nil` (no crash).
    * **Literals** — `true`, `false`, `nil`, integers, floats, double- or
      single-quoted strings, and list literals `["a", "b"]`.
    * **Comparisons** — `==`, `!=`, `>`, `<`, `>=`, `<=`, and `in`
      (membership: `x in [a, b]`).
    * **Boolean combinators** — `and` / `&&`, `or` / `||`, `not` / `!`.
      `&&`/`||`/`!` are truthy (`nil`/`false` are falsy, everything else
      truthy); `and`/`or`/`not` require booleans (a non-boolean operand
      raises, surfaced as `{:error, _}`).
    * A bare expression with no comparison is taken as a truthiness test:
      `artifact.done` ≡ `artifact.done` is neither `nil` nor `false`.

  Everything else — function calls, operators not listed, capturing,
  string interpolation, modules, `__MODULE__`, etc. — is rejected at
  parse time (`validate/1`) and at eval time. There is no `Code.eval`;
  the parsed AST is walked by an explicit whitelist.
  """

  @type bindings :: %{optional(:artifact) => term(), optional(:mission) => term()}

  @comparison_ops [:==, :!=, :>, :<, :>=, :<=]

  @doc """
  Parses `source` and returns `:ok` if it is a well-formed, whitelisted
  expression, `{:error, reason}` otherwise. Pure — does not evaluate.
  Use in schema validation.
  """
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(source) when is_binary(source) do
    case parse(source) do
      {:ok, ast} -> check(ast)
      {:error, _} = err -> err
    end
  end

  def validate(other), do: {:error, {:not_a_string, other}}

  @doc """
  Parses + whitelist-validates `source` and returns the AST. Use at
  schema-load time to cache the compiled form — `eval_ast/2` then skips
  the parse and whitelist check on every poll tick.
  """
  @spec compile(String.t()) :: {:ok, Macro.t()} | {:error, term()}
  def compile(source) when is_binary(source) do
    with {:ok, ast} <- parse(source),
         :ok <- check(ast) do
      {:ok, ast}
    end
  end

  def compile(other), do: {:error, {:not_a_string, other}}

  @doc """
  Evaluates `source` against `bindings` (`%{artifact: ..., mission: ...}`).
  Returns `{:ok, boolean()}` — the result is coerced to a boolean via
  truthiness — or `{:error, reason}` if the expression is malformed or a
  strict boolean operator got a non-boolean operand.

  Prefer `compile/1` + `eval_ast/2` for repeated evaluation (e.g.
  conditional `next:` rules evaluated on every poll tick); `eval/2` does
  the parse + whitelist check on every call.
  """
  @spec eval(String.t(), bindings()) :: {:ok, boolean()} | {:error, term()}
  def eval(source, bindings \\ %{}) when is_binary(source) do
    with {:ok, ast} <- compile(source) do
      eval_ast(ast, bindings)
    end
  end

  @doc """
  Evaluates a pre-compiled AST (from `compile/1`) against `bindings`.
  Skips the parse + whitelist check — safe because `compile/1` validated
  them — so this is the hot-path entry point for conditional-rule
  evaluation.
  """
  @spec eval_ast(Macro.t(), bindings()) :: {:ok, boolean()} | {:error, term()}
  def eval_ast(ast, bindings) do
    try do
      {:ok, truthy?(do_eval(ast, bindings))}
    rescue
      e -> {:error, {:eval_error, Exception.message(e)}}
    end
  end

  # -- Parsing ---------------------------------------------------------------

  defp parse(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_meta, msg, token}} -> {:error, {:parse_error, "#{inspect(msg)} #{inspect(token)}"}}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  # -- Whitelist check (static, pre-eval) ------------------------------------

  defp check(ast) do
    cond do
      literal?(ast) ->
        :ok

      list_literal?(ast) ->
        Enum.reduce_while(ast, :ok, fn node, :ok ->
          case check(node) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      path?(ast) ->
        :ok

      true ->
        check_op(ast)
    end
  end

  defp check_op({op, _, [l, r]}) when op in @comparison_ops or op in [:and, :or, :&&, :||] do
    with :ok <- check(l), do: check(r)
  end

  defp check_op({:in, _, [l, r]}) do
    with :ok <- check(l), do: check(r)
  end

  defp check_op({op, _, [x]}) when op in [:not, :!], do: check(x)

  defp check_op(other), do: {:error, {:disallowed_expression, Macro.to_string(other)}}

  # -- Recognizers -----------------------------------------------------------

  defp literal?(v) when is_integer(v) or is_float(v) or is_binary(v) or is_boolean(v) or is_nil(v),
    do: true

  defp literal?(_), do: false

  defp list_literal?(v) when is_list(v), do: true
  defp list_literal?(_), do: false

  # `artifact` / `mission` as a bare variable, or any dotted access chain
  # rooted at one of them: `{{:., _, [base, key]}, _, []}` with `key` an atom.
  defp path?({var, _, ctx}) when var in [:artifact, :mission] and (is_nil(ctx) or is_atom(ctx)),
    do: true

  defp path?({{:., _, [base, key]}, _, []}) when is_atom(key), do: path?(base)
  defp path?(_), do: false

  # -- Evaluation ------------------------------------------------------------

  defp do_eval(v, _b) when is_integer(v) or is_float(v) or is_binary(v) or is_boolean(v) or is_nil(v),
    do: v

  defp do_eval(list, b) when is_list(list), do: Enum.map(list, &do_eval(&1, b))

  defp do_eval({var, _, ctx}, b) when var in [:artifact, :mission] and (is_nil(ctx) or is_atom(ctx)),
    do: fetch_root(var, b)

  defp do_eval({{:., _, [base, key]}, _, []}, b) when is_atom(key) do
    case do_eval(base, b) do
      m when is_map(m) -> Map.get(m, key) || Map.get(m, Atom.to_string(key))
      _ -> nil
    end
  end

  defp do_eval({:==, _, [l, r]}, b), do: do_eval(l, b) == do_eval(r, b)
  defp do_eval({:!=, _, [l, r]}, b), do: do_eval(l, b) != do_eval(r, b)
  defp do_eval({:>, _, [l, r]}, b), do: do_eval(l, b) > do_eval(r, b)
  defp do_eval({:<, _, [l, r]}, b), do: do_eval(l, b) < do_eval(r, b)
  defp do_eval({:>=, _, [l, r]}, b), do: do_eval(l, b) >= do_eval(r, b)
  defp do_eval({:<=, _, [l, r]}, b), do: do_eval(l, b) <= do_eval(r, b)

  defp do_eval({:in, _, [l, r]}, b) do
    case do_eval(r, b) do
      list when is_list(list) -> Enum.member?(list, do_eval(l, b))
      _ -> false
    end
  end

  defp do_eval({:and, _, [l, r]}, b), do: do_eval(l, b) and do_eval(r, b)
  defp do_eval({:or, _, [l, r]}, b), do: do_eval(l, b) or do_eval(r, b)
  defp do_eval({:&&, _, [l, r]}, b), do: do_eval(l, b) && do_eval(r, b)
  defp do_eval({:||, _, [l, r]}, b), do: do_eval(l, b) || do_eval(r, b)
  defp do_eval({:not, _, [x]}, b), do: not do_eval(x, b)
  defp do_eval({:!, _, [x]}, b), do: !do_eval(x, b)

  defp fetch_root(:artifact, b), do: Map.get(b, :artifact)
  defp fetch_root(:mission, b), do: Map.get(b, :mission)

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true
end
