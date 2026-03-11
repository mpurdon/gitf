defmodule GiTF.CLI.Completions do
  @moduledoc """
  Generates shell completion scripts for bash, zsh, and fish.

  Each generator builds a string from the command tree defined in this
  module. The command tree mirrors the dispatch structure in `GiTF.CLI`.
  """

  @command_tree %{
    "quest" => ~w(new list plan start status show report merge close kill),
    "ghost" => ~w(list spawn stop context revive status),
    "comb" => ~w(add list use show remove),
    "job" => ~w(show reset kill),
    "plugin" => ~w(list install remove),
    "jobs" => ~w(list show create reset),
    "costs" => ~w(summary record),
    "waggle" => ~w(list show send),
    "cell" => ~w(list clean),
    "handoff" => ~w(create show),
    "conflict" => ~w(check),
    "github" => ~w(pr issues sync)
  }

  @top_commands ~w(
    quest ghost comb job jobs plugin doctor dashboard costs status version
    init server queen onboard verify quality intelligence heal optimize
    deadlock monitor accept scope prime quickref drone budget watch
    validate handoff conflict github cell waggle completions
  )

  # -- Public API --------------------------------------------------------------

  @doc """
  Generates a shell completion script for the given shell.

  Returns the script as a string.
  """
  @spec generate(:bash | :zsh | :fish) :: String.t()
  def generate(:bash), do: bash_completions()
  def generate(:zsh), do: zsh_completions()
  def generate(:fish), do: fish_completions()

  def generate(shell) do
    "# Unknown shell: #{shell}\n# Supported shells: bash, zsh, fish\n"
  end

  # -- Bash --------------------------------------------------------------------

  defp bash_completions do
    subcommand_cases =
      @command_tree
      |> Enum.map(fn {cmd, subs} ->
        "        #{cmd}) COMPREPLY=($(compgen -W \"#{Enum.join(subs, " ")}\" -- \"$cur\")) ;;"
      end)
      |> Enum.join("\n")

    """
    # Bash completions for gitf
    # Add to ~/.bashrc: eval "$(gitf completions bash)"

    _gitf_completions() {
        local cur prev commands
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        commands="#{Enum.join(@top_commands, " ")}"

        if [ "$COMP_CWORD" -eq 1 ]; then
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            return 0
        fi

        case "${COMP_WORDS[1]}" in
    #{subcommand_cases}
            *) COMPREPLY=() ;;
        esac

        return 0
    }

    complete -F _gitf_completions gitf
    """
  end

  # -- Zsh ---------------------------------------------------------------------

  defp zsh_completions do
    subcommand_cases =
      @command_tree
      |> Enum.map(fn {cmd, subs} ->
        quoted = Enum.map(subs, &"'#{&1}'") |> Enum.join(" ")
        "        #{cmd}) compadd #{quoted} ;;"
      end)
      |> Enum.join("\n")

    """
    # Zsh completions for gitf
    # Add to ~/.zshrc: eval "$(gitf completions zsh)"

    _ gitf() {
        local -a commands
        commands=(#{Enum.map(@top_commands, &"'#{&1}'") |> Enum.join(" ")})

        if (( CURRENT == 2 )); then
            compadd "${commands[@]}"
            return
        fi

        case "${words[2]}" in
    #{subcommand_cases}
            *) ;;
        esac
    }

    compdef _gitf gitf
    """
  end

  # -- Fish --------------------------------------------------------------------

  defp fish_completions do
    top_lines =
      @top_commands
      |> Enum.map(fn cmd ->
        "complete -c section -n '__fish_use_subcommand' -a '#{cmd}'"
      end)
      |> Enum.join("\n")

    sub_lines =
      @command_tree
      |> Enum.flat_map(fn {cmd, subs} ->
        Enum.map(subs, fn sub ->
          "complete -c section -n '__fish_seen_subcommand_from #{cmd}' -a '#{sub}'"
        end)
      end)
      |> Enum.join("\n")

    """
    # Fish completions for gitf
    # Add to ~/.config/fish/completions/gitf.fish

    #{top_lines}

    #{sub_lines}
    """
  end
end
