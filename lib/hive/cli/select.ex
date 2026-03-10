defmodule Hive.CLI.Select do
  @moduledoc """
  Arrow-key driven selection prompts for the CLI.

  Options can be plain strings or structured maps with `:label`, `:description`,
  and `:recommended` keys. Structured options get a description panel below the
  list that updates as you navigate, and a ★ badge on recommended choices.
  """

  @colors [:cyan, :green, :magenta, :yellow, :light_blue, :light_green]
  @panel_lines 3

  @doc """
  Single-select: arrow keys to navigate, enter to confirm.

  Options can be strings or maps: `%{"label" => "...", "description" => "...", "recommended" => true}`

  Returns the selected label string, or nil if cancelled.
  """
  def select(prompt, options) when is_list(options) and options != [] do
    opts = normalize(options)
    count = length(opts)
    lines = total_lines(opts)

    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts(hint("↑/↓ navigate · enter select · esc cancel"))
    IO.puts("")
    for _ <- 1..lines, do: IO.write("\n")

    result =
      with_raw_mode(fn tty ->
        IO.write("\e[?25l")
        result = select_loop(tty, opts, 0, count, lines)
        IO.write("\e[?25h")
        result
      end)

    clear_menu(lines)

    case result do
      {:ok, idx} ->
        selected = Enum.at(opts, idx)
        color = color_for(idx)
        IO.puts("  " <> color <> "→ " <> selected.label <> IO.ANSI.reset())
        selected.label

      :cancelled ->
        nil
    end
  end

  def select(_prompt, _options), do: nil

  @doc """
  Multi-select: arrow keys to navigate, space to toggle, enter to confirm.

  Options can be strings or maps (same as `select/2`).

  Returns list of selected label strings, or nil if cancelled.
  """
  def multi_select(prompt, options) when is_list(options) and options != [] do
    opts = normalize(options)
    count = length(opts)
    lines = total_lines(opts)

    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts(hint("↑/↓ navigate · space toggle · enter confirm · esc cancel"))
    IO.puts("")
    for _ <- 1..lines, do: IO.write("\n")

    result =
      with_raw_mode(fn tty ->
        IO.write("\e[?25l")
        result = multi_loop(tty, opts, 0, MapSet.new(), count, lines)
        IO.write("\e[?25h")
        result
      end)

    clear_menu(lines)

    case result do
      {:ok, selected_set} ->
        items =
          selected_set
          |> MapSet.to_list()
          |> Enum.sort()
          |> Enum.map(fn idx -> {idx, Enum.at(opts, idx)} end)

        Enum.each(items, fn {idx, item} ->
          color = color_for(idx)
          IO.puts("  " <> color <> "→ " <> item.label <> IO.ANSI.reset())
        end)

        labels = Enum.map(items, fn {_, item} -> item.label end)
        if labels == [], do: nil, else: labels

      :cancelled ->
        nil
    end
  end

  def multi_select(_prompt, _options), do: nil

  # -- Option normalization ----------------------------------------------------

  defp normalize(options) do
    Enum.map(options, fn
      opt when is_binary(opt) ->
        %{label: opt, description: nil, recommended: false}

      %{"label" => label} = opt ->
        %{
          label: label,
          description: opt["description"],
          recommended: opt["recommended"] == true
        }

      %{label: label} = opt ->
        %{
          label: label,
          description: opt[:description],
          recommended: opt[:recommended] == true
        }
    end)
  end

  defp has_details?(opts) do
    Enum.any?(opts, fn o -> o.description != nil or o.recommended end)
  end

  defp total_lines(opts) do
    count = length(opts)
    if has_details?(opts), do: count + 1 + @panel_lines, else: count
  end

  # -- Single select loop ------------------------------------------------------

  defp select_loop(tty, opts, cursor, count, lines) do
    render_single(opts, cursor, lines)

    case read_key(tty) do
      :up -> select_loop(tty, opts, max(cursor - 1, 0), count, lines)
      :down -> select_loop(tty, opts, min(cursor + 1, count - 1), count, lines)
      :enter -> {:ok, cursor}
      :escape -> :cancelled
      _ -> select_loop(tty, opts, cursor, count, lines)
    end
  end

  # -- Multi select loop -------------------------------------------------------

  defp multi_loop(tty, opts, cursor, selected, count, lines) do
    render_multi(opts, cursor, selected, lines)

    case read_key(tty) do
      :up ->
        multi_loop(tty, opts, max(cursor - 1, 0), selected, count, lines)

      :down ->
        multi_loop(tty, opts, min(cursor + 1, count - 1), selected, count, lines)

      :space ->
        toggled =
          if MapSet.member?(selected, cursor),
            do: MapSet.delete(selected, cursor),
            else: MapSet.put(selected, cursor)

        multi_loop(tty, opts, cursor, toggled, count, lines)

      :enter ->
        {:ok, selected}

      :escape ->
        :cancelled

      _ ->
        multi_loop(tty, opts, cursor, selected, count, lines)
    end
  end

  # -- Rendering ---------------------------------------------------------------

  defp render_single(opts, cursor, lines) do
    IO.write("\e[#{lines}A")
    has_panel = has_details?(opts)

    Enum.with_index(opts, fn opt, idx ->
      render_option_line(opt, idx, idx == cursor)
    end)

    if has_panel do
      render_panel(Enum.at(opts, cursor), cursor)
    end
  end

  defp render_multi(opts, cursor, selected, lines) do
    IO.write("\e[#{lines}A")
    has_panel = has_details?(opts)

    Enum.with_index(opts, fn opt, idx ->
      active = idx == cursor
      checked = MapSet.member?(selected, idx)
      color = color_for(idx)

      {box, label, star} =
        if active do
          bx =
            if checked,
              do: IO.ANSI.reverse() <> color <> " ✓ " <> IO.ANSI.reset() <> " ",
              else: IO.ANSI.reverse() <> IO.ANSI.faint() <> "   " <> IO.ANSI.reset() <> " "

          lb = IO.ANSI.bright() <> color <> opt.label
          st = if opt.recommended, do: " " <> IO.ANSI.yellow() <> "★", else: ""
          {bx, lb, st}
        else
          bx =
            if checked,
              do: color <> "[" <> IO.ANSI.bright() <> "✓" <> IO.ANSI.reset() <> color <> "]" <> IO.ANSI.reset() <> " ",
              else: IO.ANSI.faint() <> "[ ]" <> IO.ANSI.reset() <> " "

          lb = IO.ANSI.faint() <> opt.label
          st = if opt.recommended, do: " " <> IO.ANSI.faint() <> IO.ANSI.yellow() <> "★", else: ""
          {bx, lb, st}
        end

      IO.write("\r\e[2K    " <> box <> label <> star <> IO.ANSI.reset() <> "\r\n")
    end)

    if has_panel do
      render_panel(Enum.at(opts, cursor), cursor)
    end
  end

  defp render_option_line(opt, idx, active) do
    color = color_for(idx)

    if active do
      star = if opt.recommended, do: " " <> IO.ANSI.yellow() <> "★", else: ""

      IO.write(
        "\r\e[2K  " <>
          IO.ANSI.reverse() <> color <> " " <> opt.label <> " " <> IO.ANSI.reset() <>
          star <> IO.ANSI.reset() <> "\r\n"
      )
    else
      star =
        if opt.recommended,
          do: " " <> IO.ANSI.faint() <> IO.ANSI.yellow() <> "★" <> IO.ANSI.reset(),
          else: ""

      IO.write(
        "\r\e[2K    " <> IO.ANSI.faint() <> opt.label <> IO.ANSI.reset() <> star <> "\r\n"
      )
    end
  end

  defp render_panel(opt, cursor_idx) do
    color = color_for(cursor_idx)
    width = max(term_width() - 8, 40)

    # Separator
    sep = String.duplicate("─", min(width, 50))
    IO.write("\r\e[2K    " <> IO.ANSI.faint() <> sep <> IO.ANSI.reset() <> "\r\n")

    # Build content lines
    content =
      build_panel_content(opt, color, width)
      |> Enum.take(@panel_lines)

    # Render exactly @panel_lines lines
    Enum.each(0..(@panel_lines - 1), fn i ->
      line = Enum.at(content, i, "")
      IO.write("\r\e[2K" <> line <> "\r\n")
    end)
  end

  defp build_panel_content(opt, color, width) do
    badge =
      if opt.recommended,
        do: [
          "    " <>
            IO.ANSI.yellow() <>
            IO.ANSI.bright() <> "★ Recommended" <> IO.ANSI.reset()
        ],
        else: []

    desc =
      if opt.description do
        opt.description
        |> wrap_text(width)
        |> Enum.map(fn line ->
          "    " <> color <> line <> IO.ANSI.reset()
        end)
      else
        []
      end

    badge ++ desc
  end

  # -- Helpers -----------------------------------------------------------------

  defp color_for(idx) do
    color_name = Enum.at(@colors, rem(idx, length(@colors)))
    apply(IO.ANSI, color_name, [])
  end

  defp hint(text) do
    "  " <> IO.ANSI.faint() <> IO.ANSI.italic() <> text <> IO.ANSI.reset()
  end

  defp wrap_text(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      if current == "" do
        [word | rest]
      else
        if String.length(current) + 1 + String.length(word) > width do
          [word, current | rest]
        else
          [current <> " " <> word | rest]
        end
      end
    end)
    |> Enum.reverse()
  end

  defp term_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end

  # -- Terminal control --------------------------------------------------------

  defp clear_menu(count) do
    IO.write("\e[#{count}A")
    for _ <- 1..count, do: IO.write("\e[2K\n")
    IO.write("\e[#{count}A")
  end

  defp with_raw_mode(fun) do
    saved = :os.cmd(~c"stty -g </dev/tty") |> List.to_string() |> String.trim()

    if saved != "" do
      :os.cmd(~c"stty raw -echo </dev/tty")

      case :file.open(~c"/dev/tty", [:read, :raw, :binary]) do
        {:ok, tty} ->
          try do
            fun.(tty)
          after
            :file.close(tty)
            :os.cmd(String.to_charlist("stty #{saved} </dev/tty"))
          end

        {:error, _} ->
          :os.cmd(String.to_charlist("stty #{saved} </dev/tty"))
          fun.(nil)
      end
    else
      fun.(nil)
    end
  end

  defp read_key(nil), do: :unknown

  defp read_key(tty) do
    case :file.read(tty, 1) do
      {:ok, <<27>>} ->
        # Arrow keys send ESC [ X almost instantly in raw mode
        case :file.read(tty, 1) do
          {:ok, <<?[>>} ->
            case :file.read(tty, 1) do
              {:ok, <<?A>>} -> :up
              {:ok, <<?B>>} -> :down
              _ -> :unknown
            end

          _ ->
            :escape
        end

      {:ok, <<13>>} -> :enter
      {:ok, <<10>>} -> :enter
      {:ok, <<32>>} -> :space
      {:ok, <<3>>} -> :escape
      {:ok, <<"j">>} -> :down
      {:ok, <<"k">>} -> :up
      {:ok, _} -> :unknown
      :eof -> :escape
      {:error, _} -> :escape
    end
  end
end
