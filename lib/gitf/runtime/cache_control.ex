defmodule GiTF.Runtime.CacheControl do
  @moduledoc """
  Helper module for injecting cache control markers into LLM prompts.

  Supports Anthropic's prompt caching by adding `cache_control: %{"type" => "ephemeral"}`
  to specific blocks.
  """

  @doc """
  Injects cache control into a system prompt message based on the model provider.
  """
  def mark_system_prompt(content, model) do
    if should_cache?(content) do
      case provider(model) do
        :anthropic ->
          %{
            role: :system,
            content: content,
            cache_control: %{"type" => "ephemeral"}
          }

        # Google/Gemini uses a different mechanism (Context Caching resources)
        # created via API, not inline headers. We handle this elsewhere or skip.
        _ ->
          %{role: :system, content: content}
      end
    else
      %{role: :system, content: content}
    end
  end

  @doc """
  Injects cache control into a user message based on the model provider.
  """
  def mark_user_message(content, model) do
    if should_cache?(content) do
      case provider(model) do
        :anthropic ->
          %{
            role: :user,
            content: content,
            cache_control: %{"type" => "ephemeral"}
          }

        _ ->
          %{role: :user, content: content}
      end
    else
      %{role: :user, content: content}
    end
  end

  defp provider(model) do
    cond do
      String.starts_with?(model, "anthropic") -> :anthropic
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "google") -> :google
      String.starts_with?(model, "gemini") -> :google
      true -> :unknown
    end
  end

  @doc """
  Determines if caching should be applied based on content length.
  (Anthropic requires >1024 tokens for caching to be effective/allowed).
  """
  def should_cache?(nil), do: false

  def should_cache?(content) when is_binary(content) do
    # Rough estimate: 4 chars per token. 1024 tokens ~ 4096 chars.
    String.length(content) > 4000
  end

  def should_cache?(_), do: false
end
