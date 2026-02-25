defmodule Hive.Ingestion.Watchdog do
  @moduledoc """
  Monitors the .hive/inbox directory for new work orders.
  
  Any .md file dropped here is treated as a Quest definition.
  The factory ingests it, spawns a quest, and moves the file to .hive/archive.
  """

  use GenServer
  require Logger

  @interval :timer.seconds(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    hive_root = Keyword.get(opts, :hive_root, File.cwd!())
    inbox_dir = Path.join([hive_root, ".hive", "inbox"])
    archive_dir = Path.join([hive_root, ".hive", "archive"])
    
    File.mkdir_p!(inbox_dir)
    File.mkdir_p!(archive_dir)
    
    schedule_scan()
    
    {:ok, %{inbox: inbox_dir, archive: archive_dir}}
  end

  @impl true
  def handle_info(:scan, state) do
    scan_inbox(state)
    schedule_scan()
    {:noreply, state}
  end

  defp schedule_scan do
    Process.send_after(self(), :scan, @interval)
  end

  defp scan_inbox(%{inbox: inbox, archive: archive}) do
    case File.ls(inbox) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.each(fn file -> process_file(file, inbox, archive) end)
      
      {:error, reason} ->
        Logger.error("Failed to scan inbox: #{inspect(reason)}")
    end
  end

  defp process_file(filename, inbox, archive) do
    inbox_path = Path.join(inbox, filename)
    archive_path = Path.join(archive, "#{DateTime.utc_now() |> DateTime.to_unix()}_#{filename}")
    
    with {:ok, content} <- File.read(inbox_path),
         {:ok, quest} <- create_quest_from_file(filename, content),
         :ok <- File.rename(inbox_path, archive_path) do
      
      Logger.info("Ingested work order: #{filename} -> Quest #{quest.id}")
    else
      {:error, reason} ->
        Logger.error("Failed to ingest #{filename}: #{inspect(reason)}")
    end
  end

  defp create_quest_from_file(filename, content) do
    # Simple heuristic: Use filename as title, content as goal/description
    title = Path.rootname(filename) |> String.replace("_", " ") |> String.capitalize()
    
    # We need a comb. For now, assume the current working directory's main comb.
    # A robust implementation might parse "Comb: xxx" from the file.
    # We'll use the default/first comb found.
    
    case Hive.Comb.list() do
      [comb | _] ->
        Hive.Quests.create(%{
          name: title,
          goal: content,
          comb_id: comb.id,
          source: "inbox:#{filename}"
        })
      
      [] ->
        {:error, "No combs available to assign quest"}
    end
  end
end
