defmodule GiTF.CLI.Select do
  @moduledoc """
  Interactive text-based selection prompts for the CLI.

  For interactive arrow-key selection, uses raw terminal mode.
  Provides simple numbered-list fallbacks for non-interactive contexts.

  Options can be plain strings or structured maps with `:label`, `:description`,
  and `:recommended` keys.
  """

  @doc """
  Single-select: displays options, user navigates with arrows, selects with Enter.
  Returns the selected label string, or nil if cancelled.
  """
  def select(prompt, options) when is_list(options) and options != [] do
    opts = normalize(options)

    if tty?() do
      case do_interactive(prompt, opts, false) do
        {:ok, selected} -> selected.label
        _ -> nil
      end
    else
      fallback_select(prompt, opts)
    end
  end

  def select(_prompt, _options), do: nil

  @doc """
  Multi-select: displays options, user navigates with arrows, toggles with Space, selects with Enter.
  Returns list of selected label strings, or nil if cancelled.
  """
  def multi_select(prompt, options) when is_list(options) and options != [] do
    opts = normalize(options)

    if tty?() do
      case do_interactive(prompt, opts, true) do
        {:ok, selected} -> Enum.map(selected, & &1.label)
        _ -> nil
      end
    else
      fallback_multi_select(prompt, opts)
    end
  end

  def multi_select(_prompt, _options), do: nil

  # -- Interactive Implementation ----------------------------------------------

  defp tty? do
    IO.ANSI.enabled?()
  end

  defp do_interactive(prompt, opts, multi?) do
    # hide cursor
    IO.write("\e[?25l")
    stty_save = System.cmd("stty", ["-g"], stderr_to_stdout: true) |> elem(0) |> String.trim()
    System.cmd("stty", ["raw", "-echo"], stderr_to_stdout: true)

    try do
      IO.write("\r\n")
      IO.write("\r  \e[1;36m#{prompt}\e[0m\r\n")
      IO.write("\r\n")

      lines_to_clear = length(opts)

      # Initial render
      render_options(opts, 0, MapSet.new(), multi?)

      result = loop(opts, 0, MapSet.new(), multi?, lines_to_clear)

      # Clear menu
      IO.write("\r\e[#{lines_to_clear}A\e[J")
      # clear empty line above
      IO.write("\e[1A\e[J")
      # clear prompt line
      IO.write("\e[1A\e[J")

      case result do
        {:ok, selected} ->
          if multi? do
            labels = Enum.map(selected, & &1.label)
            IO.write("\r  \e[1;36m#{prompt}\e[0m\r\n")
            IO.write("\r  \e[32m→ \e[0m#{Enum.join(labels, ", ")}\r\n\r\n")
          else
            IO.write("\r  \e[1;36m#{prompt}\e[0m\r\n")
            IO.write("\r  \e[32m→ \e[0m#{selected.label}\r\n\r\n")
          end

          {:ok, selected}

        :cancel ->
          IO.write("\r  \e[1;36m#{prompt}\e[0m\r\n")
          IO.write("\r  \e[31mCancelled\e[0m\r\n\r\n")
          :cancel
      end
    after
      System.cmd("stty", [stty_save], stderr_to_stdout: true)
      # show cursor
      IO.write("\e[?25h")
    end
  end

  defp loop(opts, cursor, selected, multi?, lines_to_clear) do
    count = length(opts)

    case IO.getn(:stdio, "", 1) do
      "\r" ->
        if multi? do
          {:ok,
           Enum.filter(Enum.with_index(opts), fn {_, i} -> MapSet.member?(selected, i) end)
           |> Enum.map(&elem(&1, 0))}
        else
          {:ok, Enum.at(opts, cursor)}
        end

      "\n" ->
        if multi? do
          {:ok,
           Enum.filter(Enum.with_index(opts), fn {_, i} -> MapSet.member?(selected, i) end)
           |> Enum.map(&elem(&1, 0))}
        else
          {:ok, Enum.at(opts, cursor)}
        end

      " " ->
        if multi? do
          new_selected =
            if MapSet.member?(selected, cursor),
              do: MapSet.delete(selected, cursor),
              else: MapSet.put(selected, cursor)

          IO.write("\r\e[#{lines_to_clear}A")
          render_options(opts, cursor, new_selected, multi?)
          loop(opts, cursor, new_selected, multi?, lines_to_clear)
        else
          loop(opts, cursor, selected, multi?, lines_to_clear)
        end

      "q" ->
        :cancel

      "\e" ->
        case IO.getn(:stdio, "", 2) do
          "[A" ->
            new_cursor = max(0, cursor - 1)
            IO.write("\r\e[#{lines_to_clear}A")
            render_options(opts, new_cursor, selected, multi?)
            loop(opts, new_cursor, selected, multi?, lines_to_clear)

          "[B" ->
            new_cursor = min(count - 1, cursor + 1)
            IO.write("\r\e[#{lines_to_clear}A")
            render_options(opts, new_cursor, selected, multi?)
            loop(opts, new_cursor, selected, multi?, lines_to_clear)

          _ ->
            loop(opts, cursor, selected, multi?, lines_to_clear)
        end

      # Ctrl+C
      <<3>> ->
        :cancel

      # Ctrl+D
      <<4>> ->
        :cancel

      _ ->
        loop(opts, cursor, selected, multi?, lines_to_clear)
    end
  end

  defp render_options(opts, cursor, selected, multi?) do
    Enum.with_index(opts)
    |> Enum.each(fn {opt, idx} ->
      is_active = idx == cursor
      is_selected = MapSet.member?(selected, idx)

      pointer = if is_active, do: "\e[36m❯\e[0m", else: " "

      checkbox =
        cond do
          multi? and is_selected -> "\e[32m◉\e[0m"
          multi? -> "◯"
          true -> ""
        end

      star = if opt.recommended, do: " \e[33m★\e[0m", else: ""

      color = if is_active, do: "\e[36m", else: "\e[0m"

      prefix = if multi?, do: "#{pointer} #{checkbox} ", else: "#{pointer} "

      IO.write("\r  #{prefix}#{color}#{opt.label}\e[0m#{star}\e[K\r\n")
    end)
  end

  # -- Fallbacks ---------------------------------------------------------------

  defp fallback_select(prompt, opts) do
    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts("")

    Enum.with_index(opts, 1)
    |> Enum.each(fn {opt, idx} ->
      star = if opt.recommended, do: " " <> IO.ANSI.yellow() <> "★" <> IO.ANSI.reset(), else: ""
      label = IO.ANSI.bright() <> opt.label <> IO.ANSI.reset()
      IO.puts("  #{idx}. #{label}#{star}")

      if opt.description do
        IO.puts("     " <> IO.ANSI.faint() <> opt.description <> IO.ANSI.reset())
      end
    end)

    IO.puts("")
    answer = IO.gets("  Select [1-#{length(opts)}]: ") |> to_string() |> String.trim()

    case Integer.parse(answer) do
      {n, _} when n >= 1 and n <= length(opts) ->
        selected = Enum.at(opts, n - 1)
        IO.puts("  " <> IO.ANSI.green() <> "→ " <> selected.label <> IO.ANSI.reset())
        selected.label

      _ ->
        default = Enum.find(opts, List.first(opts), & &1.recommended)
        IO.puts("  " <> IO.ANSI.green() <> "→ " <> default.label <> IO.ANSI.reset())
        default.label
    end
  end

  defp fallback_multi_select(prompt, opts) do
    IO.puts("")
    IO.puts("  " <> IO.ANSI.bright() <> IO.ANSI.cyan() <> prompt <> IO.ANSI.reset())
    IO.puts("  " <> IO.ANSI.faint() <> "(Enter numbers separated by commas)" <> IO.ANSI.reset())
    IO.puts("")

    Enum.with_index(opts, 1)
    |> Enum.each(fn {opt, idx} ->
      star = if opt.recommended, do: " " <> IO.ANSI.yellow() <> "★" <> IO.ANSI.reset(), else: ""
      label = IO.ANSI.bright() <> opt.label <> IO.ANSI.reset()
      IO.puts("  #{idx}. #{label}#{star}")

      if opt.description do
        IO.puts("     " <> IO.ANSI.faint() <> opt.description <> IO.ANSI.reset())
      end
    end)

    IO.puts("")
    answer = IO.gets("  Select [1-#{length(opts)}]: ") |> to_string() |> String.trim()

    selected =
      answer
      |> String.split(~r/[,\s]+/)
      |> Enum.flat_map(fn s ->
        case Integer.parse(String.trim(s)) do
          {n, _} when n >= 1 and n <= length(opts) -> [Enum.at(opts, n - 1)]
          _ -> []
        end
      end)

    if selected == [] do
      nil
    else
      Enum.each(selected, fn opt ->
        IO.puts("  " <> IO.ANSI.green() <> "→ " <> opt.label <> IO.ANSI.reset())
      end)

      Enum.map(selected, & &1.label)
    end
  end

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
end
