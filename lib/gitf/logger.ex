defmodule GiTF.Logger do
  @moduledoc """
  Structured logging helpers with correlation across processes.

  Sets metadata on ghost/op/mission processes so all log lines include
  identifying fields. Filterable by ghost_id, op_id, mission_id.
  """

  require Logger

  @doc "Sets process metadata for a ghost."
  @spec set_ghost_context(String.t(), String.t(), String.t() | nil) :: :ok
  def set_ghost_context(ghost_id, op_id, mission_id \\ nil) do
    meta = [ghost_id: ghost_id, op_id: op_id]
    meta = if mission_id, do: Keyword.put(meta, :mission_id, mission_id), else: meta
    Logger.metadata(meta)
    :ok
  end

  @doc "Sets process metadata for the Major."
  @spec set_major_context() :: :ok
  def set_major_context do
    Logger.metadata(role: :major)
    :ok
  end

  @doc "Sets process metadata for a MissionServer."
  @spec set_mission_context(String.t()) :: :ok
  def set_mission_context(mission_id) do
    Logger.metadata(role: :mission_server, mission_id: mission_id)
    :ok
  end

  @doc "Logs a structured event at info level."
  @spec info(String.t(), keyword()) :: :ok
  def info(message, extra \\ []) do
    Logger.info(message, extra)
  end

  @doc "Logs a structured event at warning level."
  @spec warn(String.t(), keyword()) :: :ok
  def warn(message, extra \\ []) do
    Logger.warning(message, extra)
  end

  @doc "Logs a structured event at error level."
  @spec error(String.t(), keyword()) :: :ok
  def error(message, extra \\ []) do
    Logger.error(message, extra)
  end
end
