defmodule GiTF.Runtime.CLICallTracker do
  @moduledoc """
  Turns a CLI ghost's `stream-json` byte stream into one
  `GiTF.Runtime.CallMetrics` record per MODEL CALL.

  Every implementation, validation, design, planning, simplify and fix
  ghost is a CLI subprocess, and none of them touched `CallMetrics` — so
  the overwhelming majority of the factory's LLM work produced no latency
  data at all. This module is the missing half.

  ## A ghost run is not a call

  A ghost is an agent loop: N model calls with local tool execution
  between them. Booking a six-minute run as one record would drop a
  360_000ms "call" into the same percentile bucket as a 4_000ms HTTP
  completion and quietly ruin every number the tool reports. So the
  transcript is decomposed and each record is stamped `unit: :call`; the
  fallback for a CLI we cannot decompose is stamped `unit: :run`, and
  `CallMetrics.stats/1` groups on that field so the two never mix.

  ## What marks a call

  One model call is one distinct assistant `message.id`. The CLI emits an
  `"assistant"` event per *content block*, so the same id arrives two to
  four times carrying byte-identical usage — measured over real
  transcripts, 9_126 assistant events for 5_151 calls. De-duplicating by
  id is the difference between real numbers and a ~1.8x inflation of both
  the call count and the token totals.

  ## What a call's duration is

  The interval from the moment the CLI had everything it needed to issue
  the call to the moment the finished assistant message arrived:

    * `system` (init) — the first call starts here, so CLI boot is not
      counted as model time
    * `user` (tool results) — the next call starts here, so local tool
      execution is not counted as model time
    * `assistant` — the call ends; a record is emitted

  Boundaries are port-message arrival times, which include stream
  buffering: a few milliseconds against calls measured in seconds.

  ## Partial lines

  Port chunks split mid-line and `StreamParser.parse_chunk/1` silently
  drops any line it cannot decode. An assistant event carrying a whole
  message is precisely the line most likely to straddle a read boundary,
  so this tracker carries the trailing fragment across chunks rather than
  losing the call it describes.

  ## Bounds

  At most 500 call records per run. A ghost is already capped at an hour
  of wall clock, a run making more calls than that is pathological, and
  500 samples settle any percentile this tool computes.

  Pure data transformation: bytes in, records out. It opens no processes,
  writes nothing, and never raises — the caller decides what to do with
  the records.
  """

  @max_records 500

  # A single assistant line can legitimately reach a megabyte. Beyond this
  # the fragment is not a line, it is a leak; drop it and lose one record.
  @max_buffer_bytes 4_000_000

  @type call_record :: map()

  @type t :: %__MODULE__{
          meta: map(),
          buffer: binary(),
          started_ms: integer() | nil,
          boundary_ms: integer() | nil,
          open_id: String.t() | nil,
          pending?: boolean(),
          emitted: non_neg_integer(),
          run_input: non_neg_integer() | nil,
          run_output: non_neg_integer() | nil
        }

  defstruct meta: %{},
            buffer: "",
            started_ms: nil,
            boundary_ms: nil,
            open_id: nil,
            pending?: true,
            emitted: 0,
            run_input: nil,
            run_output: nil

  @doc """
  Starts a tracker for one CLI subprocess.

  `:provider`, `:model`, `:mode` and `:mission_id` are stamped onto every
  record. The model is a fallback only — a record prefers the model the
  CLI names in the assistant message, which is the one that actually
  served the call.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    %__MODULE__{
      meta: %{
        provider: Keyword.get(opts, :provider, "cli"),
        model: to_string(Keyword.get(opts, :model) || "unknown"),
        mode: Keyword.get(opts, :mode, :cli),
        mission_id: Keyword.get(opts, :mission_id)
      },
      started_ms: now,
      boundary_ms: now
    }
  end

  @doc """
  Consumes one port chunk, returning the advanced tracker and the call
  records the chunk completed (usually none, occasionally one).
  """
  @spec consume(t(), binary(), integer()) :: {t(), [call_record()]}
  def consume(%__MODULE__{} = tracker, data, now_ms) when is_binary(data) do
    {lines, buffer} = split_lines(tracker.buffer <> data)

    {tracker, records} =
      lines
      |> Enum.flat_map(&decode/1)
      |> Enum.reduce({%{tracker | buffer: buffer}, []}, fn event, {tracker, records} ->
        case observe(tracker, event, now_ms) do
          {tracker, nil} -> {tracker, records}
          {tracker, record} -> {tracker, [record | records]}
        end
      end)

    {tracker, Enum.reverse(records)}
  end

  def consume(tracker, _data, _now_ms), do: {tracker, []}

  @doc """
  Closes the run out.

  Emits one final record when there is something honest to say:

    * a run whose transcript yielded no calls at all (a CLI we cannot
      decompose, or one that died before speaking) books a single
      `unit: :run` record, so no execution path is invisible
    * a run killed with a call in flight books that call with the killing
      `outcome` — a timeout is exactly the signal a degradation question
      is asking about

  A clean run that already booked its calls emits nothing further.
  """
  @spec finish(t(), atom(), integer()) :: {t(), [call_record()]}
  def finish(%__MODULE__{emitted: 0} = tracker, outcome, now_ms) do
    {%{tracker | pending?: false}, [run_record(tracker, outcome, now_ms)]}
  end

  def finish(%__MODULE__{pending?: true} = tracker, outcome, now_ms) when outcome != :ok do
    {%{tracker | pending?: false}, [interrupted_record(tracker, outcome, now_ms)]}
  end

  def finish(%__MODULE__{} = tracker, _outcome, _now_ms), do: {%{tracker | pending?: false}, []}

  def finish(tracker, _outcome, _now_ms), do: {tracker, []}

  @doc "How many per-call records this run has booked."
  @spec emitted(t()) :: non_neg_integer()
  def emitted(%__MODULE__{emitted: n}), do: n
  def emitted(_), do: 0

  # -- Event interpretation ----------------------------------------------------

  # Repeat content blocks of the message already booked. Same id, same
  # usage — booking them again inflates calls and tokens by ~1.8x.
  defp observe(
         %{open_id: id} = tracker,
         %{"type" => "assistant", "message" => %{"id" => id}},
         _now
       )
       when is_binary(id),
       do: {tracker, nil}

  defp observe(tracker, %{"type" => "assistant", "message" => %{} = message}, now_ms) do
    advanced = %{
      tracker
      | open_id: Map.get(message, "id"),
        boundary_ms: now_ms,
        pending?: false
    }

    case call_record(tracker, message, now_ms) do
      nil -> {advanced, nil}
      record -> {%{advanced | emitted: tracker.emitted + 1}, record}
    end
  end

  # Tool results are back, so the next call starts now: the seconds the
  # CLI spent running a test suite are not provider latency.
  defp observe(tracker, %{"type" => "user"}, now_ms),
    do: {%{tracker | boundary_ms: now_ms, pending?: true}, nil}

  # The CLI finished booting. Call one starts here, not at spawn.
  defp observe(tracker, %{"type" => "system"}, now_ms),
    do: {%{tracker | boundary_ms: now_ms, pending?: true}, nil}

  # The terminal event closes the session, not a call — the last assistant
  # message was booked when it arrived. Its usage is the run total, kept
  # for the `unit: :run` fallback.
  defp observe(tracker, %{"type" => "result"} = event, _now_ms) do
    usage = Map.get(event, "usage") || %{}

    {%{
       tracker
       | pending?: false,
         run_input: Map.get(usage, "input_tokens") || tracker.run_input,
         run_output: Map.get(usage, "output_tokens") || tracker.run_output
     }, nil}
  end

  defp observe(tracker, _event, _now_ms), do: {tracker, nil}

  # -- Records -----------------------------------------------------------------

  defp call_record(%{emitted: n}, _message, _now_ms) when n >= @max_records, do: nil

  defp call_record(tracker, message, now_ms) do
    usage = Map.get(message, "usage") || %{}

    tracker.meta
    |> Map.merge(%{
      kind: :cli_call,
      unit: :call,
      duration_ms: elapsed(tracker.boundary_ms, now_ms),
      ttft_ms: nil,
      streaming: false,
      input_tokens: Map.get(usage, "input_tokens"),
      output_tokens: Map.get(usage, "output_tokens"),
      outcome: :ok
    })
    |> put_model(Map.get(message, "model"))
  end

  defp interrupted_record(tracker, outcome, now_ms) do
    Map.merge(tracker.meta, %{
      kind: :cli_call,
      unit: :call,
      duration_ms: elapsed(tracker.boundary_ms, now_ms),
      ttft_ms: nil,
      streaming: false,
      outcome: outcome
    })
  end

  defp run_record(tracker, outcome, now_ms) do
    Map.merge(tracker.meta, %{
      kind: :cli_run,
      unit: :run,
      duration_ms: elapsed(tracker.started_ms, now_ms),
      ttft_ms: nil,
      streaming: false,
      input_tokens: tracker.run_input,
      output_tokens: tracker.run_output,
      outcome: outcome
    })
  end

  defp put_model(record, model) when is_binary(model) and model != "",
    do: Map.put(record, :model, model)

  defp put_model(record, _model), do: record

  # -- Line framing ------------------------------------------------------------

  defp split_lines(binary) do
    case :binary.split(binary, "\n", [:global]) do
      [only] -> {[], carry(only)}
      parts -> {Enum.drop(parts, -1), carry(List.last(parts))}
    end
  end

  defp carry(tail) when byte_size(tail) > @max_buffer_bytes, do: ""
  defp carry(tail), do: tail

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> [event]
      _ -> []
    end
  end

  defp elapsed(nil, _now_ms), do: nil
  defp elapsed(start_ms, now_ms), do: max(now_ms - start_ms, 0)
end
