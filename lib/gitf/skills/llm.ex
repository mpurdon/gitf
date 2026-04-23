defmodule GiTF.Skills.LLM do
  @moduledoc """
  Shared LLM-call helpers for the skill library — used by both the
  refiner and critic to avoid duplicating response-text extraction and
  prompt-input truncation logic.
  """

  alias GiTF.Runtime.LLMClient

  @doc """
  Calls the configured LLM and extracts the assistant's text content.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate_and_extract(String.t(), String.t() | list() | struct(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_and_extract(model, messages, opts \\ []) do
    case LLMClient.generate_text(model, messages, opts) do
      {:ok, response} -> {:ok, extract_text(response)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Pulls the assistant's text out of a ReqLLM response (or a bare string).
  Falls back to `""` for unexpected shapes.
  """
  @spec extract_text(any()) :: String.t()
  def extract_text(%{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{text: t} when is_binary(t) -> [t]
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  def extract_text(%{text: text}) when is_binary(text), do: text
  def extract_text(text) when is_binary(text), do: text
  def extract_text(_), do: ""

  @doc """
  Truncates a string to at most `max` bytes, appending `"..."` when cut.
  Nil-safe.
  """
  @spec truncate(String.t() | nil, pos_integer()) :: String.t()
  def truncate(nil, _), do: ""
  def truncate(str, max) when byte_size(str) <= max, do: str
  def truncate(str, max), do: binary_part(str, 0, max) <> "..."
end
