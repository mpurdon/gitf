defmodule GiTF.Sentry.IssueIndex do
  @moduledoc """
  Secondary index for Sentry-derived missions, keyed by
  `{sector_id, sentry_issue_id} → mission_id`.

  Replaces the full `:missions` collection scan in
  `GiTF.Sentry.Inbound.find_existing/2`. Each Sentry webhook event hits
  this lookup; with the volume Sentry can produce on a noisy
  application, the linear scan was the dominant cost in the
  hot path.

  Same maintenance + fallback pattern as `GiTF.Knowledge.PageIndex`:
  rebuilt lazily from the Archive on first miss, written on
  `Inbound.create_new/3`, deleted nowhere (Sentry-derived missions
  outlive the Sentry incident — when a mission terminates the
  classification stays useful for analytics).
  """

  alias GiTF.Archive

  @collection :missions
  @table :gitf_sentry_issue_index

  @spec get(String.t() | nil, String.t()) :: String.t() | nil
  def get(sector_id, issue_id) do
    ensure_table()
    maybe_rebuild_if_empty()

    case :ets.lookup(@table, {sector_id, to_string(issue_id)}) do
      [{_, id}] -> id
      [] -> nil
    end
  end

  @spec put(String.t() | nil, String.t(), String.t()) :: :ok
  def put(sector_id, issue_id, mission_id) do
    ensure_table()
    :ets.insert(@table, {{sector_id, to_string(issue_id)}, mission_id})
    :ok
  end

  @spec delete(String.t() | nil, String.t()) :: :ok
  def delete(sector_id, issue_id) do
    ensure_table()
    :ets.delete(@table, {sector_id, to_string(issue_id)})
    :ok
  end

  @doc "Rebuilds the index from the Archive's :missions collection."
  @spec rebuild() :: :ok
  def rebuild do
    ensure_table()
    :ets.delete_all_objects(@table)

    Archive.all(@collection)
    |> Enum.each(&maybe_index/1)

    :ok
  end

  defp maybe_index(%{issue_ref: %{"source" => "sentry", "issue_id" => iid}} = mission)
       when is_binary(iid) do
    :ets.insert(@table, {{mission[:sector_id], iid}, mission[:id]})
  end

  defp maybe_index(_), do: :ok

  defp maybe_rebuild_if_empty do
    case :ets.info(@table, :size) do
      0 ->
        case Archive.all(@collection) do
          [] -> :ok
          _ -> rebuild()
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
