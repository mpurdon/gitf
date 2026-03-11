defmodule GiTF.CLI.Help do
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
    IO.puts("   1. Add a codebase:    section comb add /path/to/repo --auto")
    IO.puts("   2. Create a quest:    section quest new \"Build feature X\"")
    IO.puts("   3. Start the Major:   section queen")
    IO.puts("   4. Monitor progress:  section watch")
  end

  def show_tip(:comb_added) do
    IO.puts("")
    IO.puts("💡 What's next:")
    IO.puts("   • Create a quest:     section quest new \"Your goal here\"")
    IO.puts("   • View all combs:     section comb list")
    IO.puts("   • Test validation:    cd <comb-path> && <validation-command>")
  end

  def show_tip(:quest_created) do
    IO.puts("")
    IO.puts("💡 To start working on this quest:")
    IO.puts("   • Start the Major:    section queen")
    IO.puts("   • Monitor progress:   section watch")
    IO.puts("   • View in dashboard:  section dashboard")
  end

  def show_tip(:bee_spawned) do
    IO.puts("")
    IO.puts("💡 Monitor your ghost:")
    IO.puts("   • Watch progress:     section watch")
    IO.puts("   • Check status:       section ghost list")
    IO.puts("   • View context:       section ghost context <ghost-id>")
  end

  def show_tip(:verification_failed) do
    IO.puts("")
    IO.puts("💡 To fix verification failures:")
    IO.puts("   1. Review the output above")
    IO.puts("   2. Check the job details:  section jobs show <job-id>")
    IO.puts("   3. Revive the ghost:         section ghost revive --id <ghost-id>")
    IO.puts("   4. Or manually fix and verify")
  end

  def show_tip(:context_warning) do
    IO.puts("")
    IO.puts("⚠️  Context usage is high. Consider:")
    IO.puts("   • Creating a handoff:  section handoff create --ghost <ghost-id>")
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
      $ section quest new "Add user authentication"

      # Quest with specific comb
      $ section quest new "Fix bug #123" --comb myproject

      # Quest with budget limit
      $ section quest new "Refactor module" --budget 5.00

    The Major will analyze your goal, research the codebase, create a plan,
    and spawn ghosts to execute the work.
    """
  end

  def show_examples(:comb_add) do
    """
    Examples:
      # Auto-detect project type
      $ section comb add /path/to/repo --auto

      # Manual configuration
      $ section comb add /path/to/repo --name myproject \\
          --validation-command "mix test" \\
          --merge-strategy auto_merge

      # With GitHub integration
      $ section comb add /path/to/repo --auto \\
          --github-owner myorg \\
          --github-repo myrepo

    Auto-detection supports: Elixir, JavaScript, Rust, Go, Python, Ruby, Java
    """
  end

  def show_examples(:verify) do
    """
    Examples:
      # Verify a single job
      $ section verify --job job-abc123

      # Verify all jobs in a quest
      $ section verify --quest qst-xyz789

      # Start automatic verification
      $ section drone --verify

    Verification runs the comb's validation command (e.g., tests) to ensure
    the work meets quality standards.
    """
  end

  def show_examples(:onboard) do
    """
    Examples:
      # Preview detection
      $ section onboard /path/to/project --preview

      # Quick onboard (no research)
      $ section onboard /path/to/project --quick

      # Full onboard with custom name
      $ section onboard /path/to/project --name my-app

      # Override validation command
      $ section onboard /path/to/project \\
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
    GiTF Quick Reference
    ═══════════════════════════════════════════════════════════

    Setup:
      section init ~/my-section              Initialize workspace
      section comb add <path> --auto      Add project (auto-config)
      section doctor                      Check system health

    Quests:
      section quest new "goal"            Create quest
      section quest list                  List all quests
      section quest show <id>             Show quest details
      section queen                       Start Major coordinator

    Monitoring:
      section watch                       Live progress monitor
      section dashboard                   Web UI (localhost:4040)
      section ghost list                    List all ghosts
      section costs summary               Check token costs

    Verification:
      section verify --job <id>           Verify job
      section verify --quest <id>         Verify quest
      section drone --verify              Auto-verify mode

    Quality:
      section quality check --job <id>    Check job quality
      section quality report --quest <id> Quest quality report

    Help:
      section <command> --help            Command help
      section doctor                      System diagnostics
      section --version                   Show version

    For full documentation: https://github.com/mpurdon/gitf
    """
  end
end
