defmodule GiTF.Cabinet.Ruleset do
  @moduledoc """
  A ministry's activation ruleset as something you can hold, reason about and
  edit — rather than a JDM document you have to hand-write.

  Two representations of one thing. On disk it is the JDM decision table
  `GiTF.Cabinet.JDM` evaluates, because that is what the engine runs. In the
  Console it is a list of rules:

      %{class: ["bug"], mode: ["normal", "vacation"], cap: :under, action: "wake"}

  `from_jdm/1` and `to_jdm/1` are inverses, and a test holds them to it. The
  JDM form is genuinely hostile to edit by hand — cells are keyed by the
  *column's* id and the values are quoted and comma-joined, so `rule["action"]`
  silently finds nothing — and that is exactly the sort of thing an operator
  should never have to know.

  ## Published and draft

  A ruleset spends money: a rule that turns `queue` into `wake` starts an EC2
  instance without asking anyone. So editing never touches what is running.
  `:rules` is what the Gate reads and is only ever replaced by `publish/2`;
  `:rules_draft` is the work in progress. `Gate.decide/2` needs no knowledge of
  any of this — it keeps reading `:rules`, which is the point.

  ## What a draft must prove before it can be published

  * **Coverage** — every class × mode × cap combination is decided by some
    rule. The Cabinet queues what its rules cannot decide, so an uncovered
    combination is not dangerous, but it is unintended, and unintended is how
    a factory sleeps through a production bug.
  * **A diff** — which combinations change, and whether any of them newly
    *wake*, because that is the one direction that costs money.
  * **A replay** — what the draft would have done with activations that
    actually arrived.
  """

  alias GiTF.Cabinet.{JDM, Registry}

  @classes ~w(bug pr_review feature ci noise)
  @modes ~w(normal vacation off)
  @caps [:under, :over]
  @actions ~w(wake queue drop)

  @type cap :: :any | :under | :over
  @type rule :: %{class: [String.t()], mode: [String.t()], cap: cap(), action: String.t()}

  def classes, do: @classes
  def modes, do: @modes
  def caps, do: @caps
  def actions, do: @actions

  @doc "Every combination the Cabinet can ever be asked to decide."
  @spec combinations() :: [{String.t(), String.t(), cap()}]
  def combinations do
    for c <- @classes, m <- @modes, k <- @caps, do: {c, m, k}
  end

  # ==========================================================================
  # Storage
  # ==========================================================================

  @doc "What the Gate is running for this ministry."
  @spec published(map()) :: [rule()]
  def published(ministry), do: from_jdm(ministry[:rules] || JDM.default_rules())

  @doc "The unsaved edit, or nil."
  @spec draft(map()) :: [rule()] | nil
  def draft(%{rules_draft: doc}) when is_map(doc), do: from_jdm(doc)
  def draft(_), do: nil

  @doc "The draft if there is one, else what is published — what the editor shows."
  @spec effective(map()) :: [rule()]
  def effective(ministry), do: draft(ministry) || published(ministry)

  def draft?(ministry), do: draft(ministry) != nil

  def version(%{rules_version: v}) when is_integer(v), do: v
  def version(_), do: 1

  @doc """
  Stores a draft.

  Deliberately permissive: an empty or incoherent draft is a legitimate state
  to be in halfway through an edit, and refusing to save it would mean losing
  work. `publish/2` is where a ruleset has to be complete. The `supported?`
  check is belt and braces — `to_jdm/1` always emits a runnable table today,
  and this catches it if that ever stops being true.
  """
  @spec save_draft(String.t(), [rule()]) :: {:ok, map()} | {:error, term()}
  def save_draft(id, rules) do
    doc = to_jdm(rules)

    if JDM.supported?(doc) do
      Registry.update(id, &Map.put(&1, :rules_draft, doc))
    else
      {:error, :unsupported_document}
    end
  end

  @doc "Throws the draft away. What is published is untouched, as it has been all along."
  @spec discard(String.t()) :: {:ok, map()} | {:error, term()}
  def discard(id), do: Registry.update(id, &Map.put(&1, :rules_draft, nil))

  @doc """
  Promotes the draft to the ruleset the Gate reads.

  Refuses an incomplete draft: coverage is the one property worth enforcing at
  the boundary, because everything else about a ruleset is a judgement call and
  this one is not.
  """
  @spec publish(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish(id, actor) do
    # "no draft" and "a draft that decides nothing" are different mistakes and
    # deserve different answers: one means you have not edited anything, the
    # other means you deleted every rule. Collapsing them into :no_draft told
    # an operator who had emptied the table that they had not changed it.
    case {Registry.get(id), draft(Registry.get(id))} do
      {nil, _} ->
        {:error, :not_found}

      {_ministry, nil} ->
        {:error, :no_draft}

      {_ministry, rules} ->
        case coverage(rules) do
          %{undecided: []} -> promote(id, rules, actor)
          %{undecided: undecided} -> {:error, {:undecided, length(undecided)}}
        end
    end
  end

  defp promote(id, rules, actor) do
    Registry.update(id, fn m ->
      Map.merge(m, %{
        rules: to_jdm(rules),
        rules_draft: nil,
        rules_version: version(m) + 1,
        rules_published_at: DateTime.utc_now(),
        rules_published_by: actor
      })
    end)
  end

  # ==========================================================================
  # The model
  # ==========================================================================

  @doc "Which rule decides this combination, and its 1-based position."
  @spec decide([rule()], String.t(), String.t(), cap()) :: {String.t(), pos_integer()} | nil
  def decide(rules, class, mode, cap) do
    rules
    |> Enum.with_index(1)
    |> Enum.find_value(fn {rule, n} ->
      if matches?(rule, class, mode, cap), do: {rule.action, n}
    end)
  end

  defp matches?(rule, class, mode, cap) do
    hits?(rule.class, class) and hits?(rule.mode, mode) and
      (rule.cap == :any or rule.cap == cap)
  end

  defp hits?([], _value), do: true
  defp hits?(list, value), do: value in list

  @doc """
  What this ruleset does with everything, and what it leaves undecided.

  `dead` names rules that can never fire because an earlier one already covers
  every case they match — the most common way a ruleset stops meaning what its
  author thinks it means, and invisible without this.
  """
  @spec coverage([rule()]) :: %{
          cells: [map()],
          tally: map(),
          undecided: [{String.t(), String.t(), cap()}],
          dead: [pos_integer()]
        }
  def coverage(rules) do
    cells =
      Enum.map(combinations(), fn {c, m, k} ->
        case decide(rules, c, m, k) do
          {action, n} -> %{class: c, mode: m, cap: k, action: action, rule: n}
          nil -> %{class: c, mode: m, cap: k, action: nil, rule: nil}
        end
      end)

    fired = cells |> Enum.map(& &1.rule) |> Enum.reject(&is_nil/1) |> MapSet.new()

    %{
      cells: cells,
      tally: Enum.frequencies_by(cells, & &1.action),
      undecided: for(%{action: nil} = c <- cells, do: {c.class, c.mode, c.cap}),
      dead: for(n <- 1..max(length(rules), 1), length(rules) > 0, n not in fired, do: n)
    }
  end

  @doc "Earlier rules that make the one at `index` unreachable."
  @spec shadowers([rule()], non_neg_integer()) :: [pos_integer()]
  def shadowers(rules, index) do
    rule = Enum.at(rules, index)

    combinations()
    |> Enum.filter(fn {c, m, k} -> matches?(rule, c, m, k) end)
    |> Enum.flat_map(fn {c, m, k} ->
      case decide(rules, c, m, k) do
        {_, n} when n < index + 1 -> [n]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every combination that behaves differently under `b` than under `a`.

  This is what an operator confirms — not the syntax of a rule, but the
  consequence of it.
  """
  @spec diff([rule()], [rule()]) :: [map()]
  def diff(a, b) do
    before = coverage(a).cells
    after_ = coverage(b).cells

    Enum.zip(before, after_)
    |> Enum.filter(fn {x, y} -> x.action != y.action end)
    |> Enum.map(fn {x, y} ->
      %{
        class: y.class,
        mode: y.mode,
        cap: y.cap,
        from: x.action,
        to: y.action,
        from_rule: x.rule,
        to_rule: y.rule,
        newly_wakes: y.action == "wake" and x.action != "wake"
      }
    end)
  end

  @doc "How many of those changes start a factory that would not have started."
  def newly_waking(diff), do: Enum.count(diff, & &1.newly_wakes)

  # ==========================================================================
  # Editing — every operation returns a new list, so undo is just the old one
  # ==========================================================================

  @spec move([rule()], non_neg_integer(), non_neg_integer()) :: [rule()]
  def move(rules, from, to) when from != to do
    n = length(rules)

    if from in 0..(n - 1) and to in 0..(n - 1) do
      {rule, rest} = List.pop_at(rules, from)
      List.insert_at(rest, to, rule)
    else
      rules
    end
  end

  def move(rules, _from, _to), do: rules

  @spec put([rule()], non_neg_integer(), atom(), term()) :: [rule()]
  def put(rules, index, field, value) when field in [:class, :mode, :cap, :action] do
    List.update_at(rules, index, &Map.put(&1, field, value))
  end

  @doc """
  Toggles one value in a multi-select field.

  Emptying the list means *any*, which is what an empty JDM cell means too —
  so there is no way to author a rule that matches nothing, which would be a
  rule that exists only to confuse the next reader.
  """
  @spec toggle([rule()], non_neg_integer(), atom(), String.t()) :: [rule()]
  def toggle(rules, index, field, value) when field in [:class, :mode] do
    List.update_at(rules, index, fn rule ->
      current = Map.fetch!(rule, field)
      Map.put(rule, field, if(value in current, do: current -- [value], else: current ++ [value]))
    end)
  end

  @spec insert([rule()], non_neg_integer()) :: [rule()]
  def insert(rules, index),
    do: List.insert_at(rules, index, %{class: [], mode: [], cap: :any, action: "queue"})

  @spec duplicate([rule()], non_neg_integer()) :: [rule()]
  def duplicate(rules, index),
    do: List.insert_at(rules, index + 1, Enum.at(rules, index))

  @spec delete([rule()], non_neg_integer()) :: [rule()]
  def delete(rules, index), do: List.delete_at(rules, index)

  # ==========================================================================
  # JDM ⇄ rules
  # ==========================================================================

  @doc "Reads a JDM decision table as rules. Anything else reads as no rules at all."
  @spec from_jdm(map() | nil) :: [rule()]
  def from_jdm(doc) do
    with %{"nodes" => nodes} <- doc,
         %{"content" => %{"rules" => rules} = content} <-
           Enum.find(nodes, &(&1["type"] == "decisionTableNode")) do
      ids = column_ids(content)
      Enum.map(rules, &rule_from(&1, ids))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp column_ids(content) do
    columns = (content["inputs"] || []) ++ (content["outputs"] || [])
    Map.new(columns, fn c -> {c["field"], c["id"]} end)
  end

  defp rule_from(rule, ids) do
    %{
      class: unquote_list(rule[ids["class"]]),
      mode: unquote_list(rule[ids["mode"]]),
      cap: cap_from(rule[ids["over_cap"]]),
      action: unquote_list(rule[ids["action"]]) |> List.first() || "queue"
    }
  end

  # JDM writes an unconstrained cell as an empty string and a constrained one
  # as a quoted, comma-joined list: ~s("normal", "vacation").
  defp unquote_list(nil), do: []

  defp unquote_list(cell) do
    cell
    |> to_string()
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp cap_from(cell) do
    case cell |> to_string() |> String.trim() do
      "true" -> :over
      "false" -> :under
      _ -> :any
    end
  end

  @doc "Writes rules back as the document the engine runs."
  @spec to_jdm([rule()]) :: map()
  def to_jdm(rules) do
    inputs = [
      %{"id" => "i-class", "name" => "class", "field" => "class"},
      %{"id" => "i-mode", "name" => "mode", "field" => "mode"},
      %{"id" => "i-cap", "name" => "over cap", "field" => "over_cap"}
    ]

    outputs = [%{"id" => "o-action", "name" => "action", "field" => "action"}]

    %{
      "nodes" => [
        %{
          "id" => "activation",
          "name" => "activation",
          "type" => "decisionTableNode",
          "content" => %{
            "hitPolicy" => "first",
            "inputs" => inputs,
            "outputs" => outputs,
            "rules" => rules |> Enum.with_index() |> Enum.map(&rule_to/1)
          }
        }
      ],
      "edges" => []
    }
  end

  defp rule_to({rule, i}) do
    %{
      "_id" => "r#{i}",
      "i-class" => quote_list(rule.class),
      "i-mode" => quote_list(rule.mode),
      "i-cap" => cap_to(rule.cap),
      "o-action" => quote_list([rule.action])
    }
  end

  defp quote_list([]), do: ""
  defp quote_list(values), do: Enum.map_join(values, ", ", &~s("#{&1}"))

  defp cap_to(:over), do: "true"
  defp cap_to(:under), do: "false"
  defp cap_to(_), do: ""
end
