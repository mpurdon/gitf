defmodule GiTF.Ghost.FailureClass do
  @moduledoc """
  Classifies a ghost failure reason into a small taxonomy, so reliability
  can be reported separately from capability.

  A provider 500, a factory defect, and a ghost writing bad code all used
  to land as an undifferentiated `ghost_failed` with a raw reason string —
  which makes "how many attempts did the PROVIDER burn this week?"
  unanswerable, and that number is a first-class axis when comparing
  models/providers (reliability is not skill).

  Classes:

    * `:fatal` — the environment is broken in a way no retry can fix:
      bad/absent credentials, a missing CLI binary. Retrying burns the
      op's whole budget (and, across a DAG, every op's budget) against a
      wall. The factory should fail fast and say so.
    * `:provider_error` — the LLM provider failed us: 5xx, overloaded,
      rate limit, API error surfaced through the CLI or SDK.
    * `:timeout` — the ghost or a call inside it hit a deadline.
    * `:no_changes` — the ghost claimed success but produced nothing.
    * `:blocked` — admission control / budget refused to run it.
    * `:unknown` — everything else (factory defects and genuine bad work
      land here until something distinguishes them).

  `:fatal` is tested before `:provider_error` on purpose: an auth failure
  usually arrives wrapped in the provider's generic "API error" envelope,
  so the looser provider signatures would otherwise swallow it.

  The `:fatal` signatures are deliberately narrow — provider- and
  CLI-shaped phrasings only. Bare words like "unauthorized" or
  "permission denied" show up in a ghost's own tool output, and a mission
  about authentication would trip them on every op. A false `:fatal`
  costs the op its retries, so precision beats recall here.
  """

  @fatal_signatures [
    "not authenticated",
    "authentication failed",
    "authentication_error",
    "invalid api key",
    "invalid api_key",
    "invalid x-api-key",
    "invalid bearer token",
    "command not found",
    "not installed",
    "executable not found"
  ]

  @provider_signatures [
    "api error",
    "api_error",
    "server error",
    "internal server error",
    "overloaded",
    "rate limit",
    "rate_limit",
    "usage limit",
    "too many requests",
    "service unavailable",
    "bad gateway",
    "upstream connect error",
    ~s("type":"error")
  ]

  @timeout_signatures ["timeout", "timed out", ":timeout"]

  @type class :: :fatal | :provider_error | :timeout | :no_changes | :blocked | :unknown

  @doc "Classify a failure reason (string or term) into a `t:class/0`."
  @spec classify(term()) :: class()
  def classify(reason) when is_binary(reason) do
    down = String.downcase(reason)

    cond do
      Enum.any?(@fatal_signatures, &String.contains?(down, &1)) -> :fatal
      Enum.any?(@provider_signatures, &String.contains?(down, &1)) -> :provider_error
      Enum.any?(@timeout_signatures, &String.contains?(down, &1)) -> :timeout
      String.contains?(down, "0 file changes") -> :no_changes
      String.contains?(down, ":blocked") -> :blocked
      true -> :unknown
    end
  end

  def classify(:timeout), do: :timeout
  def classify(:blocked), do: :blocked
  def classify(:enoent), do: :fatal
  def classify(reason) when is_atom(reason), do: classify(Atom.to_string(reason))
  def classify(reason), do: classify(inspect(reason))

  @doc """
  True when the failure is worth another attempt at all. `:fatal` is the
  only class that is not — every other class has at least a chance of
  succeeding on a re-run.
  """
  @spec retryable?(class()) :: boolean()
  def retryable?(:fatal), do: false
  def retryable?(_), do: true

  @doc """
  True when the attempt should NOT be charged against the op's capability
  budget. A provider 500 says nothing about whether the op is doable, so
  counting it the same as a ghost writing bad code spends the budget on
  the provider's bad day. These attempts are capped separately.
  """
  @spec provider_fault?(class()) :: boolean()
  def provider_fault?(:provider_error), do: true
  def provider_fault?(_), do: false
end
