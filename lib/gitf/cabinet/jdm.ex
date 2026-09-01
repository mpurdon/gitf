defmodule GiTF.Cabinet.JDM do
  @moduledoc """
  A deliberately small evaluator for GoRules JDM decision tables.

  Rules are stored as standard JDM JSON (so the GoRules JDM Editor can
  edit them and the zen engine could evaluate them), but the Cabinet only
  needs the first-hit decision table subset, which is ~a hundred lines of
  Elixir. The evaluator is loud about its limits: a document with
  anything beyond one decision table — expression nodes, functions,
  graphs — returns `{:error, :unsupported}` rather than guessing, and
  the Gate resolves every error to QUEUE, never wake. The zen engine via
  a Rustler NIF is the documented growth path (docs/plans/ministry.md).

  Cell syntax supported (per zen's table cells):

    * `""` — any
    * `"bug"` or `bug` — equality (strings, numbers, booleans)
    * `"bug", "pr_review"` — membership
    * `> 5`, `>= 5`, `< 5`, `<= 5` — numeric comparison

  Output cells are literals (quoted strings unquoted).
  """

  @doc """
  Evaluates a JDM document against an input map with string keys.
  Returns `{:ok, output_map, meta}` or `{:error, reason}` — the caller
  decides what an error means (the Gate: queue). `meta.rule` is the
  1-based index of the first-hit rule, so a decision can say WHICH row
  decided it, not just what was decided.
  """
  def evaluate(doc, input) when is_map(doc) and is_map(input) do
    with {:ok, table} <- decision_table(doc),
         {:ok, output, meta} <- run_table(table, input) do
      {:ok, output, meta}
    end
  end

  def evaluate(_, _), do: {:error, :invalid_document}

  @doc "True when `evaluate/2` can honestly run this document."
  def supported?(doc), do: match?({:ok, _}, decision_table(doc))

  # -- document walking --------------------------------------------------------

  defp decision_table(%{"nodes" => nodes}) when is_list(nodes) do
    tables = Enum.filter(nodes, &(&1["type"] == "decisionTableNode"))
    others = Enum.reject(nodes, &(&1["type"] in ["inputNode", "outputNode", "decisionTableNode"]))

    cond do
      others != [] -> {:error, :unsupported}
      length(tables) != 1 -> {:error, :unsupported}
      true -> {:ok, hd(tables)["content"]}
    end
  end

  defp decision_table(_), do: {:error, :invalid_document}

  defp run_table(%{"rules" => rules} = content, input) when is_list(rules) do
    hit_policy = content["hitPolicy"] || "first"
    inputs = content["inputs"] || []
    outputs = content["outputs"] || []

    if hit_policy != "first" do
      {:error, :unsupported}
    else
      rules
      |> Enum.find_index(fn rule ->
        Enum.all?(inputs, &cell_matches?(rule[&1["id"]], &1, input))
      end)
      |> case do
        nil ->
          {:error, :no_match}

        idx ->
          rule = Enum.at(rules, idx)
          output = Map.new(outputs, fn out -> {out["field"], parse_literal(rule[out["id"]])} end)
          {:ok, output, %{rule: idx + 1, rule_count: length(rules)}}
      end
    end
  end

  defp run_table(_, _), do: {:error, :invalid_document}

  # -- cells -------------------------------------------------------------------

  defp cell_matches?(cell, _input_def, _input) when cell in [nil, ""], do: true

  defp cell_matches?(cell, input_def, input) when is_binary(cell) do
    value = get_in(input, String.split(input_def["field"] || "", "."))
    cell = String.trim(cell)

    cond do
      String.contains?(cell, ",") ->
        cell |> String.split(",") |> Enum.map(&parse_literal/1) |> Enum.member?(value)

      String.starts_with?(cell, [">=", "<=", ">", "<"]) ->
        numeric_compare(cell, value)

      true ->
        parse_literal(cell) == value
    end
  end

  defp cell_matches?(_, _, _), do: false

  defp numeric_compare(cell, value) when is_number(value) do
    {op, rest} =
      case cell do
        ">=" <> r -> {:gte, r}
        "<=" <> r -> {:lte, r}
        ">" <> r -> {:gt, r}
        "<" <> r -> {:lt, r}
      end

    case Float.parse(String.trim(rest)) do
      {threshold, _} ->
        case op do
          :gte -> value >= threshold
          :lte -> value <= threshold
          :gt -> value > threshold
          :lt -> value < threshold
        end

      :error ->
        false
    end
  end

  defp numeric_compare(_, _), do: false

  defp parse_literal(nil), do: nil

  defp parse_literal(cell) when is_binary(cell) do
    trimmed = String.trim(cell)

    cond do
      trimmed == "true" -> true
      trimmed == "false" -> false
      Regex.match?(~r/^".*"$/s, trimmed) -> String.slice(trimmed, 1..-2//1)
      match?({_, ""}, Integer.parse(trimmed)) -> elem(Integer.parse(trimmed), 0)
      match?({_, ""}, Float.parse(trimmed)) -> elem(Float.parse(trimmed), 0)
      true -> trimmed
    end
  end

  defp parse_literal(other), do: other

  # -- the default ruleset -----------------------------------------------------

  @doc """
  The plan's matrix (docs/plans/ministry.md) as a JDM document: bugs and
  PR reviews wake when the ministry is not over cap and not off; features
  always queue; noise drops; and the catch-all — like every evaluation
  failure — queues.
  """
  def default_rules do
    inputs = [
      %{"id" => "i-class", "name" => "class", "field" => "class"},
      %{"id" => "i-mode", "name" => "mode", "field" => "mode"},
      %{"id" => "i-cap", "name" => "over cap", "field" => "over_cap"}
    ]

    outputs = [%{"id" => "o-action", "name" => "action", "field" => "action"}]

    rules = [
      %{
        "_id" => "r0",
        "i-class" => "",
        "i-mode" => ~s("off"),
        "i-cap" => "",
        "o-action" => ~s("queue")
      },
      %{
        "_id" => "r1",
        "i-class" => ~s("bug"),
        "i-mode" => ~s("normal", "vacation"),
        "i-cap" => "false",
        "o-action" => ~s("wake")
      },
      %{
        "_id" => "r2",
        "i-class" => ~s("pr_review"),
        "i-mode" => ~s("normal", "vacation"),
        "i-cap" => "false",
        "o-action" => ~s("wake")
      },
      %{
        "_id" => "r3",
        "i-class" => ~s("feature"),
        "i-mode" => "",
        "i-cap" => "",
        "o-action" => ~s("queue")
      },
      %{
        "_id" => "r4",
        "i-class" => ~s("ci", "noise"),
        "i-mode" => "",
        "i-cap" => "",
        "o-action" => ~s("drop")
      },
      %{"_id" => "r5", "i-class" => "", "i-mode" => "", "i-cap" => "", "o-action" => ~s("queue")}
    ]

    %{
      "contentType" => "application/vnd.gorules.decision",
      "nodes" => [
        %{"id" => "n-in", "type" => "inputNode", "name" => "request"},
        %{
          "id" => "n-table",
          "type" => "decisionTableNode",
          "name" => "activation",
          "content" => %{
            "hitPolicy" => "first",
            "inputs" => inputs,
            "outputs" => outputs,
            "rules" => rules
          }
        },
        %{"id" => "n-out", "type" => "outputNode", "name" => "decision"}
      ],
      "edges" => [
        %{"id" => "e1", "sourceId" => "n-in", "targetId" => "n-table"},
        %{"id" => "e2", "sourceId" => "n-table", "targetId" => "n-out"}
      ]
    }
  end
end
