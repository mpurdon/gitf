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

    * `:provider_error` — the LLM provider failed us: 5xx, overloaded,
      rate limit, API error surfaced through the CLI or SDK.
    * `:timeout` — the ghost or a call inside it hit a deadline.
    * `:no_changes` — the ghost claimed success but produced nothing.
    * `:blocked` — admission control / budget refused to run it.
    * `:unknown` — everything else (factory defects and genuine bad work
      land here until something distinguishes them).
  """

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

  @type class :: :provider_error | :timeout | :no_changes | :blocked | :unknown

  @doc "Classify a failure reason (string or term) into a `t:class/0`."
  @spec classify(term()) :: class()
  def classify(reason) when is_binary(reason) do
    down = String.downcase(reason)

    cond do
      Enum.any?(@provider_signatures, &String.contains?(down, &1)) -> :provider_error
      Enum.any?(@timeout_signatures, &String.contains?(down, &1)) -> :timeout
      String.contains?(down, "0 file changes") -> :no_changes
      String.contains?(down, ":blocked") -> :blocked
      true -> :unknown
    end
  end

  def classify(:timeout), do: :timeout
  def classify(:blocked), do: :blocked
  def classify(reason) when is_atom(reason), do: classify(Atom.to_string(reason))
  def classify(reason), do: classify(inspect(reason))
end
