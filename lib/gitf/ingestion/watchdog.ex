defmodule GiTF.Ingestion.Watchdog do
  @moduledoc """
  Monitors the .gitf/inbox directory for new work orders.

  Any .md file dropped here is treated as a Quest definition.
  The factory ingests it, spawns a mission, and moves the file to .gitf/archive.
  """

  use GenServer
  require Logger

  @interval :timer.seconds(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    gitf_root = Keyword.get(opts, :gitf_root, File.cwd!())
    inbox_dir = Path.join([gitf_root, ".gitf", "inbox"])
    archive_dir = Path.join([gitf_root, ".gitf", "archive"])

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
         {:ok, mission} <- create_quest_from_file(filename, content),
         :ok <- File.rename(inbox_path, archive_path) do
      Logger.info("Ingested work order: #{filename} -> Quest #{mission.id}")
    else
      {:error, reason} ->
        Logger.error("Failed to ingest #{filename}: #{inspect(reason)}")
    end
  end

  defp create_quest_from_file(filename, content) do
    # Simple heuristic: Use filename as title, content as goal/description
    title = Path.rootname(filename) |> String.replace("_", " ") |> String.capitalize()

    # We need a sector. For now, assume the current working directory's main sector.
    # A robust implementation might parse "Sector: xxx" from the file.
    # We'll use the default/first sector found.

    case GiTF.Sector.list() do
      [sector | _] ->
        GiTF.Missions.create(%{
          name: title,
          goal: content,
          sector_id: sector.id,
          source: "inbox:#{filename}"
        })

      [] ->
        {:error, "No sectors available to assign mission"}
    end
  end
end
