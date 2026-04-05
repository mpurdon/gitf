defmodule GiTF.CLI.Progress do
  @moduledoc """
  Progress indicators and spinners for long-running CLI operations.
  """

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc """
  Shows a spinner with a message while executing a function.
  """
  def with_spinner(message, fun) do
    pid = spawn_spinner(message)
    result = fun.()
    stop_spinner(pid)
    result
  end

  @doc """
  Shows a progress bar for a list of items.
  """
  def with_progress(items, message, fun) do
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, index} ->
      show_progress(message, index, total)
      result = fun.(item)
      result
    end)
    |> tap(fn _ -> IO.write("\n") end)
  end

  defp spawn_spinner(message) do
    parent = self()

    spawn(fn ->
      Stream.cycle(@spinner_frames)
      |> Enum.reduce_while(0, fn frame, _count ->
        receive do
          :stop -> {:halt, :ok}
        after
          80 ->
            IO.write("\r#{frame} #{message}")
            {:cont, 0}
        end
      end)

      send(parent, :spinner_stopped)
    end)
  end

  defp stop_spinner(pid) do
    send(pid, :stop)

    receive do
      :spinner_stopped -> IO.write("\r\e[K")
    after
      100 -> IO.write("\r\e[K")
    end
  end

  defp show_progress(message, current, total) do
    percentage = div(current * 100, total)
    bar_width = 30
    filled = div(bar_width * current, total)
    empty = bar_width - filled

    bar = String.duplicate("█", filled) <> String.duplicate("░", empty)
    IO.write("\r#{message} [#{bar}] #{current}/#{total} (#{percentage}%)")
  end
end
