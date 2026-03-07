defmodule Hive.CLI.Select do
  @moduledoc """
  Arrow-key driven selection prompts for the CLI.

  Supports single-select (enter to pick) and multi-select (space to toggle,
  enter to confirm). Uses raw terminal mode via stty and reads directly
  from /dev/tty for reliable keypress detection.
  """

  # Palette — each option gets a color cycling through these
  @colors [:cyan, :green, :magenta, :yellow, :light_blue, :light_green]

  @doc """
  Single-select: arrow keys to navigate, enter to confirm.
  Returns the selected option string, or nil if cancelled.
  """
  def select(prompt, options) when is_list(options) and options != [] do
    count = length(options)

    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts(hint("↑/↓ navigate · enter select · esc cancel"))
    IO.puts("")
    for _ <- 1..count, do: IO.write("\n")

    result =
      with_raw_mode(fn tty ->
        IO.write("\e[?25l")
        result = select_loop(tty, options, 0, count)
        IO.write("\e[?25h")
        result
      end)

    clear_menu(count)

    case result do
      {:ok, idx} ->
        selected = Enum.at(options, idx)
        color = color_for(idx)
        IO.puts("  " <> color <> "→ " <> selected <> IO.ANSI.reset())
        selected

      :cancelled ->
        nil
    end
  end

  def select(_prompt, _options), do: nil

  @doc """
  Multi-select: arrow keys to navigate, space to toggle, enter to confirm.
  Returns list of selected option strings, or nil if cancelled.
  """
  def multi_select(prompt, options) when is_list(options) and options != [] do
    count = length(options)

    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts(hint("↑/↓ navigate · space toggle · enter confirm · esc cancel"))
    IO.puts("")
    for _ <- 1..count, do: IO.write("\n")

    result =
      with_raw_mode(fn tty ->
        IO.write("\e[?25l")
        result = multi_loop(tty, options, 0, MapSet.new(), count)
        IO.write("\e[?25h")
        result
      end)

    clear_menu(count)

    case result do
      {:ok, selected_set} ->
        items =
          selected_set
          |> MapSet.to_list()
          |> Enum.sort()
          |> Enum.map(fn idx -> {idx, Enum.at(options, idx)} end)

        Enum.each(items, fn {idx, item} ->
          color = color_for(idx)
          IO.puts("  " <> color <> "→ " <> item <> IO.ANSI.reset())
        end)

        result_items = Enum.map(items, &elem(&1, 1))
        if result_items == [], do: nil, else: result_items

      :cancelled ->
        nil
    end
  end

  def multi_select(_prompt, _options), do: nil

  # -- Single select loop ------------------------------------------------------

  defp select_loop(tty, options, cursor, count) do
    render_single(options, cursor, count)

    case read_key(tty) do
      :up -> select_loop(tty, options, max(cursor - 1, 0), count)
      :down -> select_loop(tty, options, min(cursor + 1, count - 1), count)
      :enter -> {:ok, cursor}
      :escape -> :cancelled
      _ -> select_loop(tty, options, cursor, count)
    end
  end

  # -- Multi select loop -------------------------------------------------------

  defp multi_loop(tty, options, cursor, selected, count) do
    render_multi(options, cursor, selected, count)

    case read_key(tty) do
      :up ->
        multi_loop(tty, options, max(cursor - 1, 0), selected, count)

      :down ->
        multi_loop(tty, options, min(cursor + 1, count - 1), selected, count)

      :space ->
        toggled =
          if MapSet.member?(selected, cursor),
            do: MapSet.delete(selected, cursor),
            else: MapSet.put(selected, cursor)

        multi_loop(tty, options, cursor, toggled, count)

      :enter ->
        {:ok, selected}

      :escape ->
        :cancelled

      _ ->
        multi_loop(tty, options, cursor, selected, count)
    end
  end

  # -- Rendering ---------------------------------------------------------------

  defp render_single(options, cursor, count) do
    IO.write("\e[#{count}A")

    Enum.with_index(options, fn opt, idx ->
      color = color_for(idx)

      if idx == cursor do
        IO.write(
          "\r\e[2K  " <>
            IO.ANSI.bright() <> color <> "❯ " <> opt <> IO.ANSI.reset() <> "\r\n"
        )
      else
        IO.write("\r\e[2K    " <> IO.ANSI.faint() <> opt <> IO.ANSI.reset() <> "\r\n")
      end
    end)
  end

  defp render_multi(options, cursor, selected, count) do
    IO.write("\e[#{count}A")

    Enum.with_index(options, fn opt, idx ->
      active = idx == cursor
      checked = MapSet.member?(selected, idx)
      color = color_for(idx)

      ptr = if active, do: IO.ANSI.bright() <> color <> "❯ ", else: "  "

      box =
        if checked,
          do: color <> "◉ " <> IO.ANSI.reset(),
          else: IO.ANSI.faint() <> "◯ " <> IO.ANSI.reset()

      txt =
        if active,
          do: IO.ANSI.bright() <> color <> opt <> IO.ANSI.reset(),
          else: IO.ANSI.faint() <> opt <> IO.ANSI.reset()

      IO.write("\r\e[2K  " <> ptr <> IO.ANSI.reset() <> box <> txt <> "\r\n")
    end)
  end

  # -- Helpers -----------------------------------------------------------------

  defp color_for(idx) do
    color_name = Enum.at(@colors, rem(idx, length(@colors)))
    apply(IO.ANSI, color_name, [])
  end

  defp hint(text) do
    "  " <> IO.ANSI.faint() <> IO.ANSI.italic() <> text <> IO.ANSI.reset()
  end

  # -- Terminal control --------------------------------------------------------

  defp clear_menu(count) do
    IO.write("\e[#{count}A")
    for _ <- 1..count, do: IO.write("\e[2K\n")
    IO.write("\e[#{count}A")
  end

  defp with_raw_mode(fun) do
    case System.cmd("stty", ["-g"], stderr_to_stdout: true) do
      {settings, 0} ->
        settings = String.trim(settings)
        System.cmd("stty", ["raw", "-echo"], stderr_to_stdout: true)
        {:ok, tty} = :file.open(~c"/dev/tty", [:read, :raw, :binary])

        try do
          fun.(tty)
        after
          :file.close(tty)
          System.cmd("stty", [settings], stderr_to_stdout: true)
        end

      _ ->
        fun.(nil)
    end
  end

  defp read_key(nil), do: :unknown

  defp read_key(tty) do
    case :file.read(tty, 1) do
      {:ok, <<27>>} ->
        case :file.read(tty, 1) do
          {:ok, "["} ->
            case :file.read(tty, 1) do
              {:ok, "A"} -> :up
              {:ok, "B"} -> :down
              _ -> :unknown
            end

          _ ->
            :escape
        end

      {:ok, <<13>>} -> :enter
      {:ok, <<10>>} -> :enter
      {:ok, <<32>>} -> :space
      {:ok, <<3>>} -> :escape
      {:ok, "j"} -> :down
      {:ok, "k"} -> :up
      _ -> :unknown
    end
  end
end
