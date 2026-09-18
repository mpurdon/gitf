defmodule GiTF.Cabinet.Discord.Conversation do
  @moduledoc """
  What was said in one Discord channel, so a persona can remember it.

  One record per channel, keyed by the channel id — which is the first
  isolation boundary between personas. What the operator says to Kayabuki
  in `#cabinet` is stored under that channel and is never loaded for the
  Major in `#home-affairs`. There is no global transcript, and no way to
  ask for one.

  Bounded on purpose: `@keep` turns, oldest dropped, the same shape and
  pruning `GiTF.Cabinet.Activity` uses. A conversation is context for the
  next reply, not an archive — the durable record of what was *done* is
  the activity log and the factory's own audit trail, both of which
  survive independently of this.
  """

  alias GiTF.Archive

  @collection :discord_conversations
  @keep 20

  @type turn :: %{role: :operator | :persona, text: String.t(), at: DateTime.t()}

  @doc "The channel's turns, oldest first. Unknown channel → `[]`."
  @spec load(term()) :: [turn()]
  def load(channel_id) do
    case Archive.get(@collection, key(channel_id)) do
      %{turns: turns} when is_list(turns) -> turns
      _ -> []
    end
  end

  @doc """
  Appends a turn, pruning to the newest `#{@keep}`.

  Uses `Archive.update/3` with an insert fallback rather than get→put: two
  messages in one channel land in the same second often enough, and a
  read-modify-write would lose one.
  """
  @spec append(term(), :operator | :persona, String.t()) :: :ok
  def append(channel_id, role, text) when role in [:operator, :persona] do
    id = key(channel_id)
    turn = %{role: role, text: trim(text), at: DateTime.utc_now()}

    case Archive.update(@collection, id, fn record ->
           turns = (Map.get(record, :turns) || []) ++ [turn]

           {:ok,
            record
            |> Map.put(:turns, Enum.take(turns, -@keep))
            |> Map.put(:updated_at, turn.at)}
         end) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        Archive.insert(@collection, %{
          id: id,
          channel_id: to_string(channel_id),
          turns: [turn],
          updated_at: turn.at
        })

        :ok

      _ ->
        :ok
    end
  end

  @doc "Forgets a channel's conversation. The factory's own records are untouched."
  @spec clear(term()) :: :ok
  def clear(channel_id) do
    Archive.delete(@collection, key(channel_id))
    :ok
  end

  @doc """
  Renders turns for prompt injection. Empty when there is no history, so
  the caller can omit the section entirely rather than injecting a heading
  with nothing under it.
  """
  @spec render([turn()]) :: String.t()
  def render([]), do: ""

  def render(turns) do
    turns
    |> Enum.map_join("\n", fn
      %{role: :operator, text: text} -> "operator: #{text}"
      %{role: :persona, text: text} -> "you: #{text}"
    end)
  end

  @doc "How many turns are kept per channel."
  def keep, do: @keep

  defp key(channel_id), do: "dch-" <> to_string(channel_id)

  # A pasted stack trace should not become the next five prompts.
  defp trim(text) when is_binary(text), do: String.slice(text, 0, 2_000)
  defp trim(text), do: text |> inspect() |> String.slice(0, 2_000)
end
