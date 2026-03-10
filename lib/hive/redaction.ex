defmodule Hive.Redaction do
  @moduledoc """
  Pure functions for redacting secrets from strings and data structures.

  Every log line and persisted event passes through this module before
  being written, ensuring that API keys, tokens, and passwords never
  leak into files an operator might share.
  """

  # -- Pattern definitions ---------------------------------------------------

  @patterns [
    # Anthropic API keys (must precede generic sk- pattern)
    {~r/sk-ant-[A-Za-z0-9_-]+/, "[REDACTED:anthropic_key]"},
    # OpenAI API keys
    {~r/sk-[A-Za-z0-9]{20,}/, "[REDACTED:openai_key]"},
    # AWS access keys
    {~r/AKIA[A-Z0-9]{16}/, "[REDACTED:aws_key]"},
    # GitHub tokens
    {~r/gh[ps]_[A-Za-z0-9_]{36,}/, "[REDACTED:github_token]"},
    # Google API keys
    {~r/AIza[A-Za-z0-9_\-]{35}/, "[REDACTED:google_key]"},
    # Bearer tokens
    {~r/Bearer\s+[A-Za-z0-9._-]+/, "Bearer [REDACTED]"},
    # Environment variable exports with secret-indicating names
    {~r/export\s+(\w*(?:KEY|SECRET|TOKEN|PASSWORD)\w*)=(\S+)/,
     "export \\1=[REDACTED]"},
    # Generic long tokens preceded by secret-indicating words
    {~r/(?:token|key|secret|password|authorization|bearer)[\s:=]+\K[A-Za-z0-9+\/=_-]{40,}/i,
     "[REDACTED]"}
  ]

  @sensitive_names ~w(
    api_key secret token password authorization auth_token
    access_key secret_key private_key passphrase credential
    bearer api_secret signing_key encryption_key
  )

  # -- Public API ------------------------------------------------------------

  @doc """
  Replaces detected secrets in `string` with redaction markers.

  Returns `nil` unchanged for nil input.

  ## Examples

      iex> Hive.Redaction.redact("key is sk-ant-abc123XYZ")
      "key is [REDACTED:anthropic_key]"

      iex> Hive.Redaction.redact(nil)
      nil
  """
  @spec redact(String.t() | nil) :: String.t() | nil
  def redact(nil), do: nil

  def redact(string) when is_binary(string) do
    Enum.reduce(@patterns, string, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  @doc """
  Recursively walks a map or list structure and applies `redact/1` to
  all string values. Non-string leaves are returned unchanged.

  For maps with sensitive keys (see `sensitive_key?/1`), the value is
  replaced with `"[REDACTED]"` regardless of its content.

  ## Examples

      iex> Hive.Redaction.redact_map(%{name: "alice", api_key: "sk-ant-secret123"})
      %{name: "alice", api_key: "[REDACTED]"}
  """
  @spec redact_map(term()) :: term()
  def redact_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_map(value)}
      end
    end)
  end

  def redact_map(list) when is_list(list) do
    Enum.map(list, &redact_map/1)
  end

  def redact_map(string) when is_binary(string), do: redact(string)

  def redact_map(other), do: other

  @doc """
  Returns `true` if the given key name suggests it holds a secret.

  Accepts atoms and strings. Comparison is case-insensitive.

  ## Examples

      iex> Hive.Redaction.sensitive_key?(:api_key)
      true

      iex> Hive.Redaction.sensitive_key?("Authorization")
      true

      iex> Hive.Redaction.sensitive_key?(:name)
      false
  """
  @spec sensitive_key?(atom() | String.t()) :: boolean()
  def sensitive_key?(key) when is_atom(key) do
    key |> Atom.to_string() |> sensitive_key?()
  end

  def sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    Enum.any?(@sensitive_names, fn name ->
      String.contains?(normalized, name)
    end)
  end
end
