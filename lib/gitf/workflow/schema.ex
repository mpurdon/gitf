defmodule GiTF.Workflow.Schema do
  @moduledoc """
  Schema validation for parsed YAML workflow specs.

  Catches misconfiguration at load time rather than runtime:

    * Missing required fields (`name`, `phases`)
    * Phase id collisions
    * `next`/`on_pass`/`on_fail` referencing unknown phase ids
      (including every target of a conditional `next` rule list)
    * Both `next` AND `on_pass`/`on_fail` set on the same phase
    * Malformed conditional branch lists on `next:`/`on_pass:`/`on_fail:`
      — a bad `when:` expression (validated against `GiTF.Workflow.Expr`'s
      grammar), a missing or duplicated `else:`, or an `else:` that isn't
      last
    * Cycles in fixed `next:` chains (verdict branches and *any*
      conditional rule list are explicitly allowed to cycle — a
      conditional rule is only taken when its expression holds)
    * `reads` referencing artifacts no earlier phase `produces`
    * Unknown handler modules (validated lazily at orchestrator
      dispatch time, not here, since handlers may be defined later in
      the boot order)

  Returns `{:ok, %GiTF.Workflow{}}` or `{:error, [{:reason, ...}]}` with
  the full list of issues so operators can fix them in one pass instead
  of a fix-validate-fix-validate loop.
  """

  alias GiTF.Workflow
  alias GiTF.Workflow.Phase

  @valid_tiers [:flash, :general, :opus, nil]
  @valid_gate_actions [:await_operator]

  @spec validate(map(), Path.t() | nil) ::
          {:ok, Workflow.t()} | {:error, [{atom(), term()}]}
  def validate(raw, source_path \\ nil) when is_map(raw) do
    with {:ok, name} <- fetch_string(raw, "name"),
         description <- raw["description"],
         {:ok, phases_raw} <- fetch_phases(raw),
         {:ok, phases} <- parse_phases(phases_raw),
         :ok <- validate_phase_graph(phases),
         :ok <- validate_artifact_dependencies(phases) do
      {:ok,
       %Workflow{
         name: name,
         description: description,
         phases: phases,
         source_path: source_path
       }}
    end
  end

  # -- Field extraction ------------------------------------------------------

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, [{:missing_field, key}]}
    end
  end

  defp fetch_phases(%{"phases" => phases}) when is_list(phases) and phases != [] do
    {:ok, phases}
  end

  defp fetch_phases(_), do: {:error, [{:missing_or_empty, "phases"}]}

  # -- Phase parsing ---------------------------------------------------------

  defp parse_phases(raw_phases) do
    {parsed, errors} =
      Enum.reduce(raw_phases, {[], []}, fn phase_map, {acc, errs} ->
        case parse_phase(phase_map) do
          {:ok, phase} -> {[phase | acc], errs}
          {:error, reasons} -> {acc, reasons ++ errs}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(parsed)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp parse_phase(%{} = m) do
    errors = []
    id = m["id"]
    errors = if is_binary(id) and id != "", do: errors, else: [{:phase_missing_id, m} | errors]

    handler =
      case m["handler"] do
        h when is_binary(h) and h != "" -> safe_module(h)
        _ -> nil
      end

    {next, next_errors} = parse_branch(id, m["next"], "next")
    {on_pass, on_pass_errors} = parse_branch(id, m["on_pass"], "on_pass")
    {on_fail, on_fail_errors} = parse_branch(id, m["on_fail"], "on_fail")
    errors = next_errors ++ on_pass_errors ++ on_fail_errors ++ errors

    has_next? = branch_present?(next)
    has_branches? = branch_present?(on_pass) and branch_present?(on_fail)

    errors =
      cond do
        has_next? and (branch_present?(on_pass) or branch_present?(on_fail)) ->
          [{:phase_next_and_branches, id} | errors]

        not has_next? and not has_branches? and id not in [nil, "end"] ->
          [{:phase_no_advance, id} | errors]

        true ->
          errors
      end

    tier =
      case m["model_tier"] do
        nil -> nil
        t when is_atom(t) -> t
        t when is_binary(t) -> atom_safe(t)
        _ -> :invalid
      end

    errors =
      if tier == :invalid or tier not in @valid_tiers,
        do: [{:phase_bad_model_tier, id, tier} | errors],
        else: errors

    timeout = m["timeout_minutes"]

    errors =
      cond do
        is_nil(timeout) -> errors
        is_integer(timeout) and timeout > 0 -> errors
        true -> [{:phase_bad_timeout, id, timeout} | errors]
      end

    max_retries = m["max_retries"] || 0

    errors =
      if is_integer(max_retries) and max_retries >= 0,
        do: errors,
        else: [{:phase_bad_max_retries, id, max_retries} | errors]

    {gate, gate_errors} = parse_gate(id, m["gate"])
    errors = gate_errors ++ errors

    on_exhausted = parse_on_exhausted(m["on_exhausted"])

    if errors == [] do
      {:ok,
       %Phase{
         id: id,
         handler: handler,
         next: next,
         on_pass: on_pass,
         on_fail: on_fail,
         max_retries: max_retries,
         model_tier: if(tier == :invalid, do: nil, else: tier),
         timeout_minutes: timeout,
         inject_knowledge: m["inject_knowledge"] == true,
         inject_skills: m["inject_skills"] == true,
         reads: list_of_strings(m["reads"]),
         produces: m["produces"],
         gate: gate,
         strategies: list_of_strings(m["strategies"]),
         on_exhausted: on_exhausted,
         meta: m["meta"] || %{}
       }}
    else
      {:error, errors}
    end
  end

  defp parse_on_exhausted(nil), do: :fail
  defp parse_on_exhausted("fail"), do: :fail
  defp parse_on_exhausted(:fail), do: :fail
  defp parse_on_exhausted("advance"), do: :advance
  defp parse_on_exhausted(:advance), do: :advance
  defp parse_on_exhausted(s) when is_binary(s), do: s
  defp parse_on_exhausted(_), do: :fail

  # A `next:` / `on_pass:` / `on_fail:` branch value is either a plain
  # string target ("end" terminates) or a list of conditional-transition
  # rules — `{"when" => "<expr>", "then" => "<id>"}` maps plus exactly
  # one trailing `{"else" => "<id>"}`. Each `when:` expression is
  # validated against `GiTF.Workflow.Expr`'s grammar here so operators
  # get the error at load time.
  defp parse_branch(_id, nil, _field), do: {nil, []}
  defp parse_branch(_id, s, _field) when is_binary(s) and s != "", do: {s, []}
  defp parse_branch(id, "", field), do: {nil, [{:phase_empty_branch, id, field}]}

  defp parse_branch(id, list, field) when is_list(list) do
    {parsed, errs} =
      Enum.reduce(list, {[], []}, fn rule, {acc, errs} ->
        case parse_transition(rule) do
          {:ok, t} -> {[t | acc], errs}
          {:error, reason} -> {acc, [{:bad_transition, id, field, reason} | errs]}
        end
      end)

    transitions = Enum.reverse(parsed)
    else_count = Enum.count(transitions, &match?({:else, _}, &1))

    structural =
      cond do
        transitions == [] -> [{:empty_conditional_branch, id, field}]
        else_count != 1 -> [{:conditional_branch_needs_one_else, id, field}]
        not match?({:else, _}, List.last(transitions)) -> [{:conditional_branch_else_not_last, id, field}]
        true -> []
      end

    if errs == [] and structural == [], do: {transitions, []}, else: {nil, structural ++ errs}
  end

  defp parse_branch(id, other, field), do: {nil, [{:bad_branch, id, field, other}]}

  defp branch_present?(b) when is_binary(b) and b != "", do: true
  defp branch_present?(b) when is_list(b) and b != [], do: true
  defp branch_present?(_), do: false

  defp parse_transition(%{"when" => w, "then" => t}) when is_binary(w) and is_binary(t) do
    case GiTF.Workflow.Expr.validate(w) do
      :ok -> {:ok, {w, t}}
      {:error, reason} -> {:error, {:bad_when_expr, w, reason}}
    end
  end

  defp parse_transition(%{"else" => t}) when is_binary(t), do: {:ok, {:else, t}}
  defp parse_transition(other), do: {:error, {:bad_transition_rule, other}}

  defp parse_phase(other), do: {:error, [{:phase_not_a_map, other}]}

  defp parse_gate(_id, nil), do: {nil, []}

  defp parse_gate(id, %{} = g) do
    when_clause = g["when"]
    action = atom_safe(g["action"])

    errors = []

    errors =
      if is_binary(when_clause), do: errors, else: [{:gate_missing_when, id} | errors]

    errors =
      if action in @valid_gate_actions,
        do: errors,
        else: [{:gate_bad_action, id, action} | errors]

    if errors == [] do
      {%{when: when_clause, action: action}, []}
    else
      {nil, errors}
    end
  end

  defp parse_gate(id, other), do: {nil, [{:gate_not_a_map, id, other}]}

  # -- Graph-level validation ------------------------------------------------

  defp validate_phase_graph(phases) do
    ids = Enum.map(phases, & &1.id)
    duplicate_ids = ids -- Enum.uniq(ids)
    valid_targets = MapSet.new(ids ++ ["end"])
    errors = []

    errors =
      Enum.reduce(duplicate_ids, errors, fn dup, acc -> [{:duplicate_phase_id, dup} | acc] end)

    errors =
      Enum.reduce(phases, errors, fn p, acc ->
        check_branch_targets(p.id, p.next, "next", valid_targets, acc)
        |> then(&check_branch_targets(p.id, p.on_pass, "on_pass", valid_targets, &1))
        |> then(&check_branch_targets(p.id, p.on_fail, "on_fail", valid_targets, &1))
      end)

    errors = errors ++ detect_unconditional_cycles(phases)

    if errors == [], do: :ok, else: {:error, Enum.uniq(errors)}
  end

  defp check_branch_targets(phase_id, branch, kind, valid, errors)
       when is_binary(branch) or is_nil(branch),
       do: check_target(phase_id, branch, kind, valid, errors)

  defp check_branch_targets(phase_id, transitions, kind, valid, errors) when is_list(transitions) do
    Enum.reduce(transitions, errors, fn {_cond, target}, acc ->
      check_target(phase_id, target, kind, valid, acc)
    end)
  end

  defp check_branch_targets(_phase_id, _branch, _kind, _valid, errors), do: errors

  defp check_target(_phase_id, nil, _kind, _valid, errors), do: errors

  defp check_target(phase_id, target, kind, valid, errors) do
    if MapSet.member?(valid, target),
      do: errors,
      else: [{:unknown_target, phase_id, kind, target} | errors]
  end

  # Walks the unconditional `next` chain from each phase. A cycle in
  # this chain means the workflow can never terminate normally; verdict
  # branches (on_pass/on_fail) are explicitly allowed to cycle.
  defp detect_unconditional_cycles(phases) do
    by_id = Map.new(phases, fn p -> {p.id, p} end)

    Enum.flat_map(phases, fn p ->
      walk_next(p.id, by_id, MapSet.new())
    end)
    |> Enum.uniq()
  end

  defp walk_next(nil, _by_id, _seen), do: []
  defp walk_next("end", _by_id, _seen), do: []

  defp walk_next(id, by_id, seen) do
    cond do
      MapSet.member?(seen, id) ->
        [{:unconditional_cycle, id}]

      not Map.has_key?(by_id, id) ->
        []

      true ->
        case Map.fetch!(by_id, id) do
          %Phase{next: next} when is_binary(next) and next != "" ->
            walk_next(next, by_id, MapSet.put(seen, id))

          _ ->
            []
        end
    end
  end

  # -- Artifact dependency validation ----------------------------------------

  # A phase may only `read` artifacts produced by a phase appearing
  # earlier in the (declared) `phases` list. Since branches mean
  # execution order isn't strictly linear, we use the declared list
  # order as the ordering authority. This catches the common "I moved
  # validation before implementation" foot-gun.
  defp validate_artifact_dependencies(phases) do
    {errors, _produced} =
      Enum.reduce(phases, {[], MapSet.new()}, fn phase, {errors, produced} ->
        missing =
          phase.reads
          |> Enum.reject(&MapSet.member?(produced, &1))
          |> Enum.map(fn r -> {:missing_artifact, phase.id, r} end)

        new_produced =
          if is_binary(phase.produces),
            do: MapSet.put(produced, phase.produces),
            else: produced

        {errors ++ missing, new_produced}
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  # -- Helpers ---------------------------------------------------------------

  defp safe_module(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError ->
      # Module isn't loaded yet — preserve the proposed name as a quoted
      # atom for later. The orchestrator does a final existence check at
      # dispatch time, so we don't fail loading here.
      String.to_atom("Elixir." <> name)
  end

  defp atom_safe(nil), do: nil
  defp atom_safe(s) when is_atom(s), do: s

  defp atom_safe(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    _ -> :invalid
  end

  defp list_of_strings(nil), do: []

  defp list_of_strings(list) when is_list(list) do
    Enum.flat_map(list, fn
      s when is_binary(s) -> [s]
      _ -> []
    end)
  end

  defp list_of_strings(_), do: []
end
