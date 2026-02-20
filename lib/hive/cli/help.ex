defmodule Hive.CLI.Help do
  @moduledoc """
  Enhanced help text with examples and tips.
  """

  @doc """
  Shows helpful tips after certain commands.
  """
  def show_tip(command)

  def show_tip(:init) do
    IO.puts("")
    IO.puts("💡 Next steps:")
    IO.puts("   1. Add a codebase:    hive comb add /path/to/repo --auto")
    IO.puts("   2. Create a quest:    hive quest new \"Build feature X\"")
    IO.puts("   3. Start the Queen:   hive queen")
    IO.puts("   4. Monitor progress:  hive watch")
  end

  def show_tip(:comb_added) do
    IO.puts("")
    IO.puts("💡 What's next:")
    IO.puts("   • Create a quest:     hive quest new \"Your goal here\"")
    IO.puts("   • View all combs:     hive comb list")
    IO.puts("   • Test validation:    cd <comb-path> && <validation-command>")
  end

  def show_tip(:quest_created) do
    IO.puts("")
    IO.puts("💡 To start working on this quest:")
    IO.puts("   • Start the Queen:    hive queen")
    IO.puts("   • Monitor progress:   hive watch")
    IO.puts("   • View in dashboard:  hive dashboard")
  end

  def show_tip(:bee_spawned) do
    IO.puts("")
    IO.puts("💡 Monitor your bee:")
    IO.puts("   • Watch progress:     hive watch")
    IO.puts("   • Check status:       hive bee list")
    IO.puts("   • View context:       hive bee context <bee-id>")
  end

  def show_tip(:verification_failed) do
    IO.puts("")
    IO.puts("💡 To fix verification failures:")
    IO.puts("   1. Review the output above")
    IO.puts("   2. Check the job details:  hive jobs show <job-id>")
    IO.puts("   3. Revive the bee:         hive bee revive --id <bee-id>")
    IO.puts("   4. Or manually fix and verify")
  end

  def show_tip(:context_warning) do
    IO.puts("")
    IO.puts("⚠️  Context usage is high. Consider:")
    IO.puts("   • Creating a handoff:  hive handoff create --bee <bee-id>")
    IO.puts("   • Simplifying the job")
    IO.puts("   • Breaking into smaller tasks")
  end

  def show_tip(_), do: :ok

  @doc """
  Shows examples for a command.
  """
  def show_examples(command)

  def show_examples(:quest_new) do
    """
    Examples:
      # Simple quest
      $ hive quest new "Add user authentication"

      # Quest with specific comb
      $ hive quest new "Fix bug #123" --comb myproject

      # Quest with budget limit
      $ hive quest new "Refactor module" --budget 5.00

    The Queen will analyze your goal, research the codebase, create a plan,
    and spawn bees to execute the work.
    """
  end

  def show_examples(:comb_add) do
    """
    Examples:
      # Auto-detect project type
      $ hive comb add /path/to/repo --auto

      # Manual configuration
      $ hive comb add /path/to/repo --name myproject \\
          --validation-command "mix test" \\
          --merge-strategy auto_merge

      # With GitHub integration
      $ hive comb add /path/to/repo --auto \\
          --github-owner myorg \\
          --github-repo myrepo

    Auto-detection supports: Elixir, JavaScript, Rust, Go, Python, Ruby, Java
    """
  end

  def show_examples(:verify) do
    """
    Examples:
      # Verify a single job
      $ hive verify --job job-abc123

      # Verify all jobs in a quest
      $ hive verify --quest qst-xyz789

      # Start automatic verification
      $ hive drone --verify

    Verification runs the comb's validation command (e.g., tests) to ensure
    the work meets quality standards.
    """
  end

  def show_examples(:onboard) do
    """
    Examples:
      # Preview detection
      $ hive onboard /path/to/project --preview

      # Quick onboard (no research)
      $ hive onboard /path/to/project --quick

      # Full onboard with custom name
      $ hive onboard /path/to/project --name my-app

      # Override validation command
      $ hive onboard /path/to/project \\
          --validation-command "npm run test:ci"

    Onboarding auto-detects language, framework, build tools, and suggests
    optimal configuration.
    """
  end

  def show_examples(_), do: ""

  @doc """
  Shows a quick reference card.
  """
  def quick_reference do
    """
    Hive Quick Reference
    ═══════════════════════════════════════════════════════════

    Setup:
      hive init ~/my-hive              Initialize workspace
      hive comb add <path> --auto      Add project (auto-config)
      hive doctor                      Check system health

    Quests:
      hive quest new "goal"            Create quest
      hive quest list                  List all quests
      hive quest show <id>             Show quest details
      hive queen                       Start Queen coordinator

    Monitoring:
      hive watch                       Live progress monitor
      hive dashboard                   Web UI (localhost:4040)
      hive bee list                    List all bees
      hive costs summary               Check token costs

    Verification:
      hive verify --job <id>           Verify job
      hive verify --quest <id>         Verify quest
      hive drone --verify              Auto-verify mode

    Quality:
      hive quality check --job <id>    Check job quality
      hive quality report --quest <id> Quest quality report

    Help:
      hive <command> --help            Command help
      hive doctor                      System diagnostics
      hive --version                   Show version

    For full documentation: https://github.com/mpurdon/hive
    """
  end
end
