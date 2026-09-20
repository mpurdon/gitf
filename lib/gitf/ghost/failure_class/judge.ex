defmodule GiTF.Ghost.FailureClass.Judge do
  @moduledoc """
  A second opinion on failures the signature matcher could not name.

  `GiTF.Ghost.FailureClass` matches substrings. That is precise on the
  phrasings it knows and blind to every other one, so novel wording lands in
  `:unknown` — and `:unknown` is where two very different things pile up
  together: the factory's own defects, and ghosts producing bad work. The
  moduledoc there says as much. This module asks a calibrated classifier to
  separate them.

  ## It only ever runs on `:unknown`

  A regex hit is never second-guessed. The signatures were written to be
  narrow precisely because a false `:fatal` costs an op its whole retry
  budget, and re-opening a decision that is already right can only make it
  wrong. So the judge sees the residue and nothing else, which also means
  the fallback is exactly today's behaviour: when it is off, times out, is
  throttled, or is unsure, the class stays `:unknown` and the Major retries
  and charges capability, as it does now.

  ## Advisory by default, promoted only on confidence

  The judge answers into a wider vocabulary than the taxonomy it feeds. Two
  of its options — `factory_defect` and `bad_work` — have no counterpart in
  `t:GiTF.Ghost.FailureClass.class/0`, and are deliberately never promoted.
  They exist to answer a question the factory currently cannot: *how many of
  my failures are my own bugs?* They are recorded on the op and read by
  reporting, and they change no control flow at all.

  The five that do exist in the taxonomy are promoted only above a
  confidence threshold, and `:fatal` has its own, higher one. That is not
  fussiness — the consequences differ by an order of magnitude. Promoting
  `:provider_error` wrongly charges one attempt to the wrong budget;
  promoting `:fatal` wrongly abandons the op with its retries unspent. The
  threshold follows the blast radius.

  Recording the verdict alongside the promoted class is what makes this a
  pilot rather than a change of behaviour: every judgement is stored with
  its confidence and full distribution, so whether the calibration holds is
  a question the Archive can answer later instead of an opinion.
  """

  require Logger

  alias GiTF.SystemOne

  @question "failure_class"

  # Promotion thresholds. `:fatal` ends the op; everything else costs at most
  # one misattributed attempt. See the moduledoc.
  @fatal_threshold 0.90
  @default_threshold 0.75

  # Options that exist in GiTF.Ghost.FailureClass and may be promoted.
  @promotable ~w(provider_error timeout fatal no_changes blocked)

  # The descriptions are the whole interface: the model never sees the
  # question id, only these. They are written to contrast with each other
  # rather than to define each class in isolation, because that is what
  # separates a choice from a guess.
  @criteria %{
    "provider_error" =>
      "The language model provider failed the request: a 5xx, an overload, " <>
        "a rate limit, a refused or malformed API response. The work itself was never attempted.",
    "timeout" =>
      "Something exceeded a deadline — the ghost, a tool call inside it, or " <>
        "the whole op — without any other error being reported.",
    "fatal" =>
      "The environment is broken in a way that re-running cannot fix: absent or " <>
        "rejected credentials, a missing executable, an unusable configuration. " <>
        "A second attempt would fail identically.",
    "no_changes" =>
      "The ghost reported success but produced no edits: an empty diff, zero files changed.",
    "blocked" =>
      "The factory itself refused to run the work — admission control, a spend cap, " <>
        "a lock it could not take. Nothing was attempted and nothing is broken.",
    "factory_defect" =>
      "A bug in GiTF rather than in the provider or the work: failed provisioning, " <>
        "a missing worktree or sector path, a crash in the orchestrator, corrupt internal " <>
        "state, an unexpected nil. The kind of failure whose fix is a change to the factory.",
    "bad_work" =>
      "The ghost ran and produced output, but the output was wrong: the code did not " <>
        "compile, tests failed, review or validation rejected it. The machinery worked; " <>
        "the result did not.",
    "unknown" => "The reason does not give enough to tell these apart. Prefer this over guessing."
  }

  @typedoc """
  What the judge concluded. `:class` is the promoted class, or `nil` when
  nothing was promoted; `:verdict` is what it actually said, always.
  """
  @type judgement :: %{
          class: GiTF.Ghost.FailureClass.class() | nil,
          verdict: String.t(),
          confidence: float(),
          probabilities: %{String.t() => number()},
          promoted: boolean()
        }

  @doc """
  Whether the judge is switched on.

  Needs its own flag *and* `GiTF.SystemOne.enabled?/0`, so the pilot can be
  turned off without disturbing anything else built on System One.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :failure_judge_enabled, false) and SystemOne.enabled?()
  end

  @doc """
  Refines a classification, or declines to.

  Returns `:skip` when there is nothing to do — the judge is off, the
  signature matcher already named the failure, or there is no reason text to
  judge. Returns `{:ok, judgement}` when it reached a verdict, whether or not
  that verdict was promoted.

  Never raises and never returns an error: a caller's only job is to store
  what comes back, and the absence of a judgement must read the same as the
  judge not being there at all.
  """
  @spec refine(GiTF.Ghost.FailureClass.class(), term()) :: {:ok, judgement()} | :skip
  def refine(:unknown, reason) do
    if enabled?(), do: judge(text(reason)), else: :skip
  end

  # A named class is already the answer. See the moduledoc.
  def refine(_class, _reason), do: :skip

  defp judge(nil), do: :skip

  defp judge(text) do
    questions = %{
      @question =>
        SystemOne.choice(
          "A job in an automated software factory failed with the text below. " <>
            "What kind of failure was it?",
          @criteria
        )
    }

    case SystemOne.ask(text, questions) do
      {:ok, response} ->
        interpret(response)

      {:error, reason} ->
        # Not a warning: being unable to reach an optional judge is a normal
        # outcome on a box that may be rate-limited or offline, and the
        # fallback is the answer the factory would have had anyway.
        Logger.debug("failure judge: unavailable (#{inspect(reason)})")
        :skip
    end
  end

  defp interpret(response) do
    case SystemOne.read_choice(response, @question) do
      {:ok, verdict, confidence} ->
        {:ok,
         %{
           class: promote(verdict, confidence),
           verdict: verdict,
           confidence: confidence,
           probabilities: SystemOne.probabilities(response, @question),
           promoted: promote(verdict, confidence) != nil
         }}

      {:error, :no_answer} ->
        :skip
    end
  end

  # Promotion is the only part of this that changes what the factory does,
  # so it is the narrowest part: a class that exists, above its threshold.
  defp promote(verdict, confidence) when verdict in @promotable do
    if confidence >= threshold(verdict), do: String.to_existing_atom(verdict), else: nil
  end

  defp promote(_verdict, _confidence), do: nil

  defp threshold("fatal"),
    do: Application.get_env(:gitf, :failure_judge_fatal_threshold, @fatal_threshold)

  defp threshold(_),
    do: Application.get_env(:gitf, :failure_judge_threshold, @default_threshold)

  # Jev takes text. A reason is usually a string already; an atom or tuple
  # from a crashed process is inspected, which is also what the signature
  # matcher sees, so both judge the same input.
  defp text(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 8_000)
    end
  end

  defp text(nil), do: nil
  defp text(reason), do: reason |> inspect(limit: 50, printable_limit: 4_000) |> text()
end
