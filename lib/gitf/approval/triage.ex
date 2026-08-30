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
  | each string in `gaps` | concerns | `:gap` |
  | `cross_check_override` present | fail | `:cross_check` |
  | `exec_validation.infra_failure == true` | concerns | `:ground_truth` |
  | contested req id with no rebutted `met: true` this round | fail | `:contested_open` |
  | no validation artifact at all | concerns | `:no_artifact` |

  Two of those rows are the whole reason this module exists:

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
          rebuttal: String.t() | nil
        }

  @type t :: %{fails: [item()], concerns: [item()], oks: [item()]}

  @doc """
  Triages a mission into `%{fails: [...], concerns: [...], oks: [...]}`.

  Sources are independent and concatenated, so a mission with no
  validation artifact still contributes its contested register and its
  ground-truth verdict rather than collapsing to a single line.
  """
  @spec build(map()) :: t()
  def build(mission) when is_map(mission) do
    artifact = validation_artifact(mission)

    (requirement_items(artifact) ++
       gap_items(artifact) ++
       cross_check_items(artifact) ++
       ground_truth_items(mission) ++
       contested_items(mission, artifact) ++
       missing_artifact_items(artifact))
    |> group()
  end

  def build(_), do: group([])

  @doc """
  The one-line count rendered beside the approve/reject buttons, e.g.
  `"0 fails · 2 concerns · 14 ok"`.
  """
  @spec tally(t()) :: String.t()
  def tally(%{fails: fails, concerns: concerns, oks: oks}) do
    "#{count(fails, "fail", "fails")} · #{count(concerns, "concern", "concerns")} · #{length(oks)} ok"
  end

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

  # -- Requirements ----------------------------------------------------------

  defp requirement_items(nil), do: []

  defp requirement_items(artifact) do
    artifact |> Map.get("requirements_met") |> List.wrap() |> Enum.map(&requirement_item/1)
  end

  # The factory's own downgrade marker. Checked first: the gate writes
  # `met: false` alongside it, so this clause and the catch-all would
  # otherwise both match and the operator would lose the reason.
  defp requirement_item(%{"rebuttal_missing" => true} = entry) do
    %{
      status: :fail,
      kind: :contested_flip,
      title: "#{req_id(entry)} — flip rejected, still unmet",
      detail:
        join(
          "Marked met over a standing UNMET verdict with no rebuttal answering it, " <>
            "so the factory downgraded it back to unmet. The claim was not argued, " <>
            "and an unargued flip is how msn-978954 shipped its gap.",
          evidence(entry)
        ),
      rebuttal: nil
    }
  end

  defp requirement_item(%{"met" => true} = entry) do
    case rebuttal(entry) do
      nil ->
        %{
          status: :ok,
          kind: :requirement,
          title: "#{req_id(entry)} met",
          detail: evidence(entry),
          rebuttal: nil
        }

      text ->
        %{
          status: :ok,
          kind: :contested_rebutted,
          title: "#{req_id(entry)} met — overturns an earlier UNMET verdict",
          detail: evidence(entry),
          rebuttal: text
        }
    end
  end

  defp requirement_item(entry) when is_map(entry) do
    %{
      status: :fail,
      kind: :requirement,
      title: "#{req_id(entry)} NOT met",
      detail: evidence(entry),
      rebuttal: nil
    }
  end

  # A non-map where a verdict belongs is not "nothing to see" — it is a
  # requirement nobody judged.
  defp requirement_item(entry) do
    %{
      status: :fail,
      kind: :requirement,
      title: "Unreadable requirement entry",
      detail:
        "The validator emitted #{inspect(entry)} where a requirement verdict belongs. " <>
          "Nothing in it can be checked.",
      rebuttal: nil
    }
  end

  defp req_id(entry) do
    case entry["req_id"] || entry["id"] do
      id when is_binary(id) and id != "" -> id
      _ -> "(unnamed requirement)"
    end
  end

  defp evidence(entry), do: text_or_nil(entry["evidence"])
  defp rebuttal(entry), do: text_or_nil(entry["rebuttal"])

  # -- Gaps ------------------------------------------------------------------

  defp gap_items(nil), do: []

  defp gap_items(artifact) do
    artifact |> Map.get("gaps") |> List.wrap() |> Enum.map(&gap_item/1)
  end

  defp gap_item(text) when is_binary(text) do
    %{status: :concerns, kind: :gap, title: headline(text), detail: text, rebuttal: nil}
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
          %{
            status: :fail,
            kind: :cross_check,
            title: "The validator said pass and a gate overrode it",
            detail: to_text(reason),
            rebuttal: nil
          }
        ]
    end
  end

  # -- Ground truth ----------------------------------------------------------

  defp ground_truth_items(mission) do
    case Map.get(artifacts(mission), "exec_validation") do
      %{"infra_failure" => true} ->
        [
          %{
            status: :concerns,
            kind: :ground_truth,
            title: "Ground truth unavailable — the pass is provisional",
            detail:
              "ground truth was unavailable this round; the pass is provisional — " <>
                "run the software yourself",
            rebuttal: nil
          }
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
  defp contested_items(mission, artifact) do
    rebutted = rebutted_ids(artifact)

    for entry <- List.wrap(Map.get(mission, :contested_requirements)),
        is_map(entry),
        id = entry["req_id"],
        is_binary(id) and id != "",
        not MapSet.member?(rebutted, id) do
      %{
        status: :fail,
        kind: :contested_open,
        title: "#{id} stands contested — this round did not rebut it",
        detail: text_or_nil(entry["reason"]) || "previously judged unmet",
        rebuttal: nil
      }
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
      %{
        status: :concerns,
        kind: :no_artifact,
        title: "No validation artifact on this mission",
        detail:
          "Nothing was recorded for validation, so there is nothing to triage. " <>
            "Approving merges work whose verdict is unknown — read the mission first.",
        rebuttal: nil
      }
    ]
  end

  defp missing_artifact_items(_), do: []

  # -- Shared ----------------------------------------------------------------

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

  defp join(text, nil), do: text
  defp join(text, extra), do: text <> "\n\nValidator's evidence: " <> extra
end
