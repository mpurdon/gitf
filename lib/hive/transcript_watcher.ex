defmodule Hive.TranscriptWatcher do
  @moduledoc """
  GenServer that polls Claude Code transcript files for new cost data.

  Rather than using file system events (which are fragile for files being
  actively written), this watcher polls on a fixed interval. It tracks
  the byte offset of each watched file so it only parses new content.

  ## State

      %{
        watched_bees: %{bee_id => %{path: String.t(), offset: non_neg_integer()}},
        poll_interval: pos_integer()
      }

  ## Usage

  Started on demand and registered in the Hive.Registry so there is at
  most one watcher process.
  """

  use GenServer
  require Logger

  @default_poll_interval 5_000
  @registry_name Hive.Registry
  @registry_key :transcript_watcher

  # -- Client API --------------------------------------------------------------

  @doc "Starts the TranscriptWatcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = {:via, Registry, {@registry_name, @registry_key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Begins watching a transcript file for a given bee.

  New cost entries will be parsed and recorded to the database
  on each poll cycle.
  """
  @spec watch(String.t(), String.t()) :: :ok
  def watch(bee_id, transcript_path) do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, {:watch, bee_id, transcript_path})
      :error -> :ok
    end
  end

  @doc """
  Stops watching the transcript file for a given bee.
  """
  @spec unwatch(String.t()) :: :ok
  def unwatch(bee_id) do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, {:unwatch, bee_id})
      :error -> :ok
    end
  end

  @doc """
  Performs a one-time parse of a transcript file for a bee.

  Reads the entire file, extracts cost entries, and records them.
  Useful for a final sweep after a bee completes its work.
  """
  @spec final_parse(String.t(), String.t()) :: :ok
  def final_parse(bee_id, transcript_path) do
    case Hive.Transcript.parse_file(transcript_path) do
      {:ok, entries} ->
        entries
        |> Hive.Transcript.extract_costs()
        |> Enum.each(&record_cost(bee_id, &1))

      {:error, _reason} ->
        :ok
    end
  end

  @doc "Looks up the watcher process via the Registry."
  @spec lookup() :: {:ok, pid()} | :error
  def lookup do
    case Registry.lookup(@registry_name, @registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    state = %{
      watched_bees: %{},
      poll_interval: interval
    }

    schedule_poll(interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:watch, bee_id, path}, _from, state) do
    watch_entry = %{path: path, offset: 0}
    watched = Map.put(state.watched_bees, bee_id, watch_entry)
    {:reply, :ok, %{state | watched_bees: watched}}
  end

  def handle_call({:unwatch, bee_id}, _from, state) do
    watched = Map.delete(state.watched_bees, bee_id)
    {:reply, :ok, %{state | watched_bees: watched}}
  end

  @impl true
  def handle_info(:poll, state) do
    watched = poll_all(state.watched_bees)
    schedule_poll(state.poll_interval)
    {:noreply, %{state | watched_bees: watched}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private helpers ---------------------------------------------------------

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_all(watched_bees) do
    Map.new(watched_bees, fn {bee_id, entry} ->
      {bee_id, poll_bee(bee_id, entry)}
    end)
  end

  defp poll_bee(bee_id, %{path: path, offset: offset} = entry) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > offset ->
        {new_entries, new_offset} = Hive.Transcript.parse_from_offset(path, offset)

        new_entries
        |> Hive.Transcript.extract_costs()
        |> Enum.each(&record_cost(bee_id, &1))

        maybe_emit_checkpoint(bee_id, new_entries)

        %{entry | offset: new_offset}

      _ ->
        entry
    end
  end

  @doc false
  def maybe_emit_checkpoint(_bee_id, entries) when entries == [], do: :ok

  def maybe_emit_checkpoint(bee_id, entries) do
    # Infer phase from tool usage patterns in transcript entries
    phase = infer_phase(entries)

    if phase do
      Hive.Waggle.send_checkpoint(bee_id, %{
        phase: phase,
        synthetic: true,
        entries_count: length(entries)
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp infer_phase(entries) do
    text =
      entries
      |> Enum.map(fn entry ->
        cond do
          is_map(entry) -> Map.get(entry, :content, Map.get(entry, "content", ""))
          is_binary(entry) -> entry
          true -> ""
        end
      end)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(text, "test") or String.contains?(text, "assert") -> "testing"
      String.contains?(text, "write") or String.contains?(text, "edit") -> "coding"
      String.contains?(text, "read") or String.contains?(text, "grep") -> "analyzing"
      true -> nil
    end
  end

  defp record_cost(bee_id, cost_data) do
    {:ok, _cost} = Hive.Costs.record(bee_id, cost_data)
    :ok
  end
end
