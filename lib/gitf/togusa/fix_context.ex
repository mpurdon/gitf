defmodule GiTF.Togusa.FixContext do
  @moduledoc """
  Tracks fix attempts across verification loops.

  Accumulates failures, feedback, and attempted remedies so each
  successive ghost gets full context of what was tried. Used by both
  Tachikoma (quality gate) and Togusa (goal fulfillment) loops.

  Stored on the op record (for quality gate fixes) or mission record
  (for goal fulfillment fixes) as a serializable map.
  """

  @type phase :: :quality_gate | :goal_fulfillment

  @type attempt_record :: %{
          attempt: pos_integer(),
          op_id: String.t(),
          phase: phase(),
          failures: map(),
          feedback_given: String.t(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          original_op_id: String.t() | nil,
          history: [attempt_record()]
        }

  @enforce_keys [:original_op_id]
  defstruct attempt: 0, max_attempts: 3, original_op_id: nil, history: []

  @doc "Creates a new fix context for an op."
  @spec new(String.t(), keyword()) :: t()
  def new(op_id, opts \\ []) do
    %__MODULE__{
      original_op_id: op_id,
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    }
  end

  @doc "Records a fix attempt with its failures and the feedback given to the ghost."
  @spec record_attempt(t(), phase(), String.t(), map(), String.t()) :: t()
  def record_attempt(%__MODULE__{} = ctx, phase, op_id, failures, feedback) do
    record = %{
      attempt: ctx.attempt + 1,
      op_id: op_id,
      phase: phase,
      failures: digest(failures),
      feedback_given: feedback,
      timestamp: DateTime.utc_now()
    }

    %{ctx | attempt: ctx.attempt + 1, history: ctx.history ++ [record]}
  end

  @doc "Returns true if all fix attempts have been exhausted."
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{attempt: attempt, max_attempts: max}), do: attempt >= max

  @doc """
  Renders the full fix history as markdown for injection into the ghost's prompt.

  Each prior attempt shows what phase failed, what the failures were,
  and what feedback was given, so the ghost can learn from prior mistakes.
  """
  @spec format_for_prompt(t()) :: String.t()
  def format_for_prompt(%__MODULE__{history: []}), do: ""

  def format_for_prompt(%__MODULE__{history: history}) do
    sections =
      Enum.map(history, fn record ->
        phase_label =
          case record.phase do
            :quality_gate -> "Code Quality"
            :goal_fulfillment -> "Goal Fulfillment"
            other -> to_string(other)
          end

        failures_text = record.failures |> digest() |> format_failures()

        """
        ### Attempt #{record.attempt} (#{phase_label})
        #{failures_text}
        **Feedback given:** #{String.slice(record.feedback_given, 0, 500)}
        """
      end)

    "## Prior Fix Attempts\n\n" <> Enum.join(sections, "\n")
  end

  @doc "Serializes the context to a plain map for Archive storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ctx) do
    %{
      attempt: ctx.attempt,
      max_attempts: ctx.max_attempts,
      original_op_id: ctx.original_op_id,
      history:
        Enum.map(ctx.history, fn r ->
          %{r | phase: to_string(r.phase), timestamp: DateTime.to_iso8601(r.timestamp)}
        end)
    }
  end

  @doc "Deserializes from a plain map (loaded from Archive)."
  @spec from_map(map()) :: t()
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    %__MODULE__{
      attempt: Map.get(map, :attempt, map["attempt"] || 0),
      max_attempts: Map.get(map, :max_attempts, map["max_attempts"] || 3),
      original_op_id: Map.get(map, :original_op_id, map["original_op_id"]),
      history:
        Map.get(map, :history, map["history"] || [])
        |> Enum.map(fn r ->
          phase =
            case Map.get(r, :phase, r["phase"]) do
              "quality_gate" -> :quality_gate
              "goal_fulfillment" -> :goal_fulfillment
              atom when is_atom(atom) -> atom
              _ -> :unknown
            end

          %{
            attempt: Map.get(r, :attempt, r["attempt"]),
            op_id: Map.get(r, :op_id, r["op_id"]),
            phase: phase,
            failures: Map.get(r, :failures, r["failures"] || %{}),
            feedback_given: Map.get(r, :feedback_given, r["feedback_given"] || ""),
            timestamp: parse_timestamp(Map.get(r, :timestamp, r["timestamp"]))
          }
        end)
    }
  rescue
    e ->
      # A shape-drift decode failure must NOT read as "first attempt" —
      # from_map(...) || new(...) would silently reset the fix budget and
      # unbound the fix loop. Preserve at least the attempt counter.
      require Logger

      Logger.warning(
        "FixContext decode failed (#{Exception.message(e)}); preserving attempt count"
      )

      %__MODULE__{
        attempt: Map.get(map, :attempt, map["attempt"] || 0),
        max_attempts: Map.get(map, :max_attempts, map["max_attempts"] || 3),
        original_op_id: Map.get(map, :original_op_id, map["original_op_id"]),
        history: []
      }
  end

  @doc """
  The fix-relevant slice of a validation artifact: unmet requirements, the
  uncovered ids, gaps, verdict and summary. Anything else — met entries,
  `raw_output`, parse bookkeeping, factory stamps — is dropped.

  Applied when an attempt is recorded, so the history persisted on the
  mission and on every later fix op is small, and again when rendering,
  so histories persisted before this existed shrink too. msn-ac0539's third
  fix prompt was 77KB, 51KB of it one prior attempt's raw stream-json
  transcript. Failures that are not validation-shaped (the quality gate's)
  pass through untouched.
  """
  @spec digest(map() | term()) :: map() | term()
  def digest(%{} = failures)
      when is_map_key(failures, "requirements_met") or is_map_key(failures, "overall_verdict") do
    unmet =
      failures
      |> Map.get("requirements_met", [])
      |> List.wrap()
      |> Enum.reject(&(is_map(&1) and Map.get(&1, "met") == true))

    failures
    |> Map.take(~w(uncovered_requirements gaps overall_verdict summary note))
    |> Map.put("requirements_met", unmet)
    |> then(fn m ->
      if Map.get(failures, "parse_failed"),
        do: Map.put(m, "note", "the validator's reply could not be parsed; its verdict is fail"),
        else: m
    end)
    |> Map.reject(fn {_k, v} -> v in [nil, [], ""] end)
  end

  def digest(other), do: other

  defp format_failures(failures) when is_map(failures) and map_size(failures) == 0,
    do: "No specific failures recorded."

  defp format_failures(failures) when is_map(failures) do
    Enum.map_join(failures, "\n", fn {key, value} -> "- **#{key}**: #{format_value(value)}" end)
  end

  defp format_failures(_), do: "No specific failures recorded."

  # Render a value for inline embedding in markdown. Lists may contain maps
  # (e.g. validation `requirements_met` is a list of %{"req_id" => ..., "met"
  # => ..., "evidence" => ...}); converting those to strings via interpolation
  # raises String.Chars. Pretty-print maps inline; keep strings as-is.
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value) or is_number(value), do: to_string(value)

  defp format_value(value) when is_list(value) do
    value |> Enum.map(&format_value/1) |> Enum.join(", ")
  end

  defp format_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
    |> Enum.join(" ")
  end

  defp format_value(value), do: inspect(value)

  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
