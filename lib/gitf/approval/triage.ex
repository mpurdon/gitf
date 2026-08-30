defmodule GiTF.Approval.Triage do
  @moduledoc """
  Turns a mission awaiting approval into the three questions an operator
  actually has to answer: what **failed**, what should give them
  **concern**, and what is **ok**.

  The approval panel used to render the goal, two buttons, and a
  `12/12 met` chip. Everything that distinguishes "ship it" from "read
  this first" — which requirement flipped, whether a gap was behavioral
  or cosmetic, whether the software was ever actually run — lived inside
  the raw validation artifact, which meant the operator either opened the
  JSON or approved blind. Nobody opens the JSON.

  Every item here is derived **mechanically** from structured fields. No
  text classification, no model call, no judgement about whether a gap
  "sounds serious". The one editorial decision is the classification
  table below, and it is deliberately fail-closed: anything the shape of
  the data leaves ambiguous lands in `:fail`, and gaps — which only
  survive onto a *pass* verdict when the validator decided they were
  advisory — always land in `:concerns`, never in `:ok`.

  ## Classification

  | Source | Status | Kind |
  |---|---|---|
  | `requirements_met` entry, `rebuttal_missing: true` | fail | `:contested_flip` |
  | `requirements_met` entry, `met: true` + a rebuttal | ok | `:contested_rebutted` |
  | `requirements_met` entry, `met: true` | ok | `:requirement` |
  | `requirements_met` entry, anything else | fail | `:requirement` |
  | requirement id in the requirements artifact with NO `requirements_met` entry | fail | `:unreported` |
  | each string in `gaps` | concerns | `:gap` |
  | `cross_check_override` present | fail | `:cross_check` |
  | `exec_validation.infra_failure == true` | concerns | `:ground_truth` |
  | contested req id with no rebutted `met: true` this round | fail | `:contested_open` |
  | no validation artifact at all | concerns | `:no_artifact` |

  Three of those rows are the whole reason this module exists:

    * **gaps are never buried.** msn-978954 shipped its FR-5 gap because
      the validator filed a behavioral defect in `gaps` as "minor,
      non-blocking" while marking the requirement met. A gap on a pass
      verdict is by definition something the validator chose not to
      block on — which is exactly where a false pass hides. Each one gets
      its own orange line.
    * **a flip must show its argument.** `met: true` carrying a rebuttal
      is `:contested_rebutted`, not a plain pass: the operator is told
      that a prior UNMET verdict was overturned, and the argument is
      carried along for them to read. Its fail-closed twin,
      `rebuttal_missing`, is the flip the factory already rejected.
    * **silence is not a pass.** A validator that simply never mentions
      a requirement used to produce a spotless panel. `:unreported`
      turns that omission into a failure, because "I did not look" and
      "it is fine" must never render the same.

  ## Requirement context

  A bare id is a citation, not information: `FR-1 met` tells an operator
  nothing about what FR-1 asked for. Every item bearing a `req_id` is
  joined against the mission's `requirements` artifact and carries the
  requirement's `requirement` text, its `priority`, and its
  `acceptance_criteria`. Ids the artifact does not know keep working with
  nils — an item is never dropped for lacking context, because the
  verdict matters more than the prose.

  `coverage` answers the question that precedes all of them: how many of
  the requirements were reported on at all this round. Without a
  requirements artifact it reports `known: false` rather than a
  meaningless `0 of 0`.

  The mission is read as-is — `:artifacts`, `:contested_requirements` —
  so `build/1` is a pure function of one map and can be tested without
  standing anything up.
  """

  @type status :: :ok | :concerns | :fail

  @type item :: %{
          status: status(),
          kind: atom(),
          title: String.t(),
          detail: String.t() | nil,
          rebuttal: String.t() | nil,
          req_id: String.t() | nil,
          requirement: String.t() | nil,
          priority: String.t() | nil,
          acceptance_criteria: [String.t()]
        }

  @type coverage :: %{known: boolean(), reported: non_neg_integer(), total: non_neg_integer()}

  @type t :: %{fails: [item()], concerns: [item()], oks: [item()], coverage: coverage()}

  # Every item carries the same keys whether or not it is about a
  # requirement, so a renderer never has to ask which shape it has.
  @no_requirement %{req_id: nil, requirement: nil, priority: nil, acceptance_criteria: []}

  @doc """
  Triages a mission into `%{fails:, concerns:, oks:, coverage:}`.

  Sources are independent and concatenated, so a mission with no
  validation artifact still contributes its contested register and its
  ground-truth verdict rather than collapsing to a single line.
  """
  @spec build(map()) :: t()
  def build(mission) when is_map(mission) do
    artifact = validation_artifact(mission)
    reqs = requirement_index(mission)

    items =
      requirement_items(artifact, reqs) ++
        unreported_items(artifact, reqs) ++
        gap_items(artifact) ++
        cross_check_items(artifact) ++
        ground_truth_items(mission) ++
        contested_items(mission, artifact, reqs) ++
        missing_artifact_items(artifact)

    items |> group() |> Map.put(:coverage, coverage(artifact, reqs))
  end

  def build(_), do: Map.put(group([]), :coverage, unknown_coverage())

  @doc """
  The one-line count rendered beside the approve/reject buttons, e.g.
  `"0 fails · 2 concerns · 14 ok"`.
  """
  @spec tally(t()) :: String.t()
  def tally(%{fails: fails, concerns: concerns, oks: oks}) do
    "#{count(fails, "fail", "fails")} · #{count(concerns, "concern", "concerns")} · #{length(oks)} ok"
  end

  @doc """
  How much of the requirements artifact this round actually reported on.

  An omission is a failure (`:unreported`), but it should be visible
  before the operator reads a single item — so it also gets its own line.
  """
  @spec coverage_line(t()) :: String.t()
  def coverage_line(%{coverage: %{known: false}}),
    do: "requirement coverage unknown — no requirements artifact on this mission"

  def coverage_line(%{coverage: %{reported: reported, total: total}}),
    do: "#{reported} of #{total} requirements reported this round"

  defp count(items, singular, plural) do
    case length(items) do
      1 -> "1 #{singular}"
      n -> "#{n} #{plural}"
    end
  end

  defp group(items) do
    %{
      fails: Enum.filter(items, &(&1.status == :fail)),
      concerns: Enum.filter(items, &(&1.status == :concerns)),
      oks: Enum.filter(items, &(&1.status == :ok))
    }
  end

  # -- Requirement context ---------------------------------------------------

  # The requirements artifact, flattened to an ordered id list plus a
  # lookup. Ids are unique across the functional and non-functional
  # lists; first writer wins if a mission ever emits a duplicate.
  #
  # `known: false` covers absent, malformed, and present-but-empty alike.
  # All three mean the same thing to an operator — nothing to compare the
  # round against — and reporting "0 of 0 requirements" would read as a
  # finding rather than an absence.
  defp requirement_index(mission) do
    case Map.get(artifacts(mission), "requirements") do
      artifact when is_map(artifact) ->
        {ids, by_id} =
          (requirement_entries(artifact, "functional_requirements") ++
             requirement_entries(artifact, "non_functional"))
          |> Enum.reduce({[], %{}}, fn {id, context}, {ids, by_id} ->
            if Map.has_key?(by_id, id),
              do: {ids, by_id},
              else: {[id | ids], Map.put(by_id, id, context)}
          end)

        ids = Enum.reverse(ids)
        %{ids: ids, by_id: by_id, known: ids != []}

      _ ->
        %{ids: [], by_id: %{}, known: false}
    end
  end

  defp requirement_entries(artifact, key) do
    for entry <- List.wrap(Map.get(artifact, key)),
        is_map(entry),
        id = entry["id"] || entry["req_id"],
        is_binary(id) and id != "" do
      {id,
       %{
         requirement: text_or_nil(entry["description"]),
         # Non-functional requirements routinely omit priority.
         priority: text_or_nil(entry["priority"]),
         acceptance_criteria: criteria(entry["acceptance_criteria"])
       }}
    end
  end

  defp criteria(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp criteria(_), do: []

  # An id the requirements artifact does not know still produces an item —
  # the verdict is the point; the prose is the enrichment.
  defp with_requirement(item, nil, _reqs), do: item

  defp with_requirement(item, id, reqs) do
    context = Map.get(reqs.by_id, id, Map.drop(@no_requirement, [:req_id]))

    item |> Map.put(:req_id, id) |> Map.merge(context)
  end

  defp coverage(_artifact, %{known: false}), do: unknown_coverage()

  defp coverage(artifact, reqs) do
    reported = reported_ids(artifact)

    %{
      known: true,
      total: length(reqs.ids),
      reported: Enum.count(reqs.ids, &MapSet.member?(reported, &1))
    }
  end

  defp unknown_coverage, do: %{known: false, reported: 0, total: 0}

  defp reported_ids(nil), do: MapSet.new()

  defp reported_ids(artifact) do
    for entry <- List.wrap(Map.get(artifact, "requirements_met")),
        is_map(entry),
        id = entry["req_id"] || entry["id"],
        is_binary(id) and id != "",
        into: MapSet.new(),
        do: id
  end

  # -- Requirements ----------------------------------------------------------

  defp requirement_items(nil, _reqs), do: []

  defp requirement_items(artifact, reqs) do
    artifact
    |> Map.get("requirements_met")
    |> List.wrap()
    |> Enum.map(&requirement_item(&1, reqs))
  end

  # The factory's own downgrade marker. Checked first: the gate writes
  # `met: false` alongside it, so this clause and the catch-all would
  # otherwise both match and the operator would lose the reason.
  defp requirement_item(%{"rebuttal_missing" => true} = entry, reqs) do
    :fail
    |> item(:contested_flip, "#{req_label(entry)} — flip rejected, still unmet",
      detail:
        join(
          "Marked met over a standing UNMET verdict with no rebuttal answering it, " <>
            "so the factory downgraded it back to unmet. The claim was not argued, " <>
            "and an unargued flip is how msn-978954 shipped its gap.",
          evidence(entry)
        )
    )
    |> with_requirement(req_id(entry), reqs)
  end

  defp requirement_item(%{"met" => true} = entry, reqs) do
    item =
      case rebuttal(entry) do
        nil ->
          item(:ok, :requirement, "#{req_label(entry)} met", detail: evidence(entry))

        text ->
          item(
            :ok,
            :contested_rebutted,
            "#{req_label(entry)} met — overturns an earlier UNMET verdict",
            detail: evidence(entry),
            rebuttal: text
          )
      end

    with_requirement(item, req_id(entry), reqs)
  end

  defp requirement_item(entry, reqs) when is_map(entry) do
    :fail
    |> item(:requirement, "#{req_label(entry)} NOT met", detail: evidence(entry))
    |> with_requirement(req_id(entry), reqs)
  end

  # A non-map where a verdict belongs is not "nothing to see" — it is a
  # requirement nobody judged.
  defp requirement_item(entry, _reqs) do
    item(:fail, :requirement, "Unreadable requirement entry",
      detail:
        "The validator emitted #{inspect(entry)} where a requirement verdict belongs. " <>
          "Nothing in it can be checked."
    )
  end

  defp req_id(entry) do
    case entry["req_id"] || entry["id"] do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp req_label(entry), do: req_id(entry) || "(unnamed requirement)"

  defp evidence(entry), do: text_or_nil(entry["evidence"])
  defp rebuttal(entry), do: text_or_nil(entry["rebuttal"])

  # -- Unreported ------------------------------------------------------------

  # "I did not look at it" and "it is fine" must never render the same.
  # The set is derived from the requirements artifact so it holds whether
  # or not the validator volunteered an `uncovered_requirements` key; that
  # key, when present, means something adjacent ("no op claimed this") and
  # is folded in rather than trusted as the source.
  defp unreported_items(artifact, reqs) do
    reported = reported_ids(artifact)
    derived = Enum.reject(reqs.ids, &MapSet.member?(reported, &1))
    uncovered = uncovered_ids(artifact)

    (derived ++ Enum.reject(uncovered, &(&1 in derived)))
    |> Enum.map(&unreported_item(&1, &1 in uncovered, reqs))
  end

  defp unreported_item(id, uncovered?, reqs) do
    :fail
    |> item(:unreported, "#{id} — never reported on this round",
      detail:
        join(
          "The validator's report contains no verdict for this requirement: not met, " <>
            "not unmet, absent. An omission renders as a clean panel, which is exactly " <>
            "the amnesia that let msn-978954 ship.",
          uncovered? &&
            "The validation artifact also lists it under uncovered_requirements — no op " <>
              "claimed to implement it."
        )
    )
    |> with_requirement(id, reqs)
  end

  defp uncovered_ids(nil), do: []

  defp uncovered_ids(artifact) do
    for entry <- List.wrap(Map.get(artifact, "uncovered_requirements")),
        id = uncovered_id(entry),
        is_binary(id) and id != "",
        uniq: true,
        do: id
  end

  defp uncovered_id(entry) when is_binary(entry), do: entry
  defp uncovered_id(entry) when is_map(entry), do: entry["req_id"] || entry["id"]
  defp uncovered_id(_), do: nil

  # -- Gaps ------------------------------------------------------------------

  defp gap_items(nil), do: []

  defp gap_items(artifact) do
    artifact |> Map.get("gaps") |> List.wrap() |> Enum.map(&gap_item/1)
  end

  defp gap_item(text) when is_binary(text) do
    item(:concerns, :gap, headline(text), detail: text)
  end

  defp gap_item(other), do: other |> inspect() |> gap_item()

  # -- Cross-check -----------------------------------------------------------

  defp cross_check_items(nil), do: []

  defp cross_check_items(artifact) do
    case Map.get(artifact, "cross_check_override") do
      nil ->
        []

      reason ->
        [
          item(:fail, :cross_check, "The validator said pass and a gate overrode it",
            detail: to_text(reason)
          )
        ]
    end
  end

  # -- Ground truth ----------------------------------------------------------

  defp ground_truth_items(mission) do
    case Map.get(artifacts(mission), "exec_validation") do
      %{"infra_failure" => true} ->
        [
          item(:concerns, :ground_truth, "Ground truth unavailable — the pass is provisional",
            detail:
              "ground truth was unavailable this round; the pass is provisional — " <>
                "run the software yourself"
          )
        ]

      _ ->
        []
    end
  end

  # -- Contested register ----------------------------------------------------

  # An id the mission carries as contested and this round did not argue
  # out of that state. The rebuttal gate makes an unargued flip
  # impossible to reach approval with, so anything still open here is
  # genuinely unresolved.
  defp contested_items(mission, artifact, reqs) do
    rebutted = rebutted_ids(artifact)

    for entry <- List.wrap(Map.get(mission, :contested_requirements)),
        is_map(entry),
        id = entry["req_id"],
        is_binary(id) and id != "",
        not MapSet.member?(rebutted, id) do
      :fail
      |> item(:contested_open, "#{id} stands contested — this round did not rebut it",
        detail: text_or_nil(entry["reason"]) || "previously judged unmet"
      )
      |> with_requirement(id, reqs)
    end
  end

  defp rebutted_ids(nil), do: MapSet.new()

  defp rebutted_ids(artifact) do
    for entry <- List.wrap(Map.get(artifact, "requirements_met")),
        is_map(entry),
        entry["met"] == true,
        is_binary(rebuttal(entry)),
        id = entry["req_id"] || entry["id"],
        is_binary(id),
        into: MapSet.new(),
        do: id
  end

  # -- No artifact -----------------------------------------------------------

  defp missing_artifact_items(nil) do
    [
      item(:concerns, :no_artifact, "No validation artifact on this mission",
        detail:
          "Nothing was recorded for validation, so there is nothing to triage. " <>
            "Approving merges work whose verdict is unknown — read the mission first."
      )
    ]
  end

  defp missing_artifact_items(_), do: []

  # -- Shared ----------------------------------------------------------------

  defp item(status, kind, title, opts) do
    Map.merge(@no_requirement, %{
      status: status,
      kind: kind,
      title: title,
      detail: Keyword.get(opts, :detail),
      rebuttal: Keyword.get(opts, :rebuttal)
    })
  end

  defp artifacts(mission) do
    case Map.get(mission, :artifacts) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp validation_artifact(mission) do
    case Map.get(artifacts(mission), "validation") do
      artifact when is_map(artifact) -> artifact
      _ -> nil
    end
  end

  @headline_length 120

  # The first line, short enough to scan a stack of them.
  defp headline(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if String.length(line) > @headline_length,
      do: String.slice(line, 0, @headline_length) <> "…",
      else: line
  end

  defp text_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text_or_nil(_), do: nil

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value)

  defp join(text, extra) when extra in [nil, false], do: text
  defp join(text, extra), do: text <> "\n\n" <> extra
end
