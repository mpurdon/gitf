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
    IO.puts("   1. Add a codebase:    section sector add /path/to/repo --auto")
    IO.puts("   2. Create a mission:    section mission new \"Build feature X\"")
    IO.puts("   3. Start the Major:   section major")
    IO.puts("   4. Monitor progress:  section watch")
  end

  def show_tip(:sector_added) do
    IO.puts("")
    IO.puts("💡 What's next:")
    IO.puts("   • Create a mission:     section mission new \"Your goal here\"")
    IO.puts("   • View all sectors:     section sector list")
    IO.puts("   • Test validation:    cd <sector-path> && <validation-command>")
  end

  def show_tip(:quest_created) do
    IO.puts("")
    IO.puts("💡 To start working on this mission:")
    IO.puts("   • Start the Major:    section major")
    IO.puts("   • Monitor progress:   section watch")
    IO.puts("   • View in dashboard:  section dashboard")
  end

  def show_tip(:ghost_spawned) do
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
    IO.puts("   2. Check the op details:  section ops show <op-id>")
    IO.puts("   3. Revive the ghost:         section ghost revive --id <ghost-id>")
    IO.puts("   4. Or manually fix and verify")
  end

  def show_tip(:context_warning) do
    IO.puts("")
    IO.puts("⚠️  Context usage is high. Consider:")
    IO.puts("   • Creating a transfer:  section transfer create --ghost <ghost-id>")
    IO.puts("   • Simplifying the op")
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
      # Simple mission
      $ section mission new "Add user authentication"

      # Quest with specific sector
      $ section mission new "Fix bug #123" --sector myproject

      # Quest with budget limit
      $ section mission new "Refactor module" --budget 5.00

    The Major will analyze your goal, research the codebase, create a plan,
    and spawn ghosts to execute the work.
    """
  end

  def show_examples(:sector_add) do
    """
    Examples:
      # Auto-detect project type
      $ section sector add /path/to/repo --auto

      # Manual configuration
      $ section sector add /path/to/repo --name myproject \\
          --validation-command "mix test" \\
          --sync-strategy auto_merge

      # With GitHub integration
      $ section sector add /path/to/repo --auto \\
          --github-owner myorg \\
          --github-repo myrepo

    Auto-detection supports: Elixir, JavaScript, Rust, Go, Python, Ruby, Java
    """
  end

  def show_examples(:verify) do
    """
    Examples:
      # Verify a single op
      $ section verify --op op-abc123

      # Verify all ops in a mission
      $ section verify --mission msn-xyz789

      # Start automatic verification
      $ section tachikoma --verify

    Audit runs the sector's validation command (e.g., tests) to ensure
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
      section sector add <path> --auto      Add project (auto-config)
      section medic                      Check system health

    Quests:
      section mission new "goal"            Create mission
      section mission list                  List all missions
      section mission show <id>             Show mission details
      section major                       Start Major coordinator

    Monitoring:
      section watch                       Live progress monitor
      section dashboard                   Web UI (localhost:4040)
      section ghost list                    List all ghosts
      section costs summary               Check token costs

    Audit:
      section verify --op <id>           Verify op
      section verify --mission <id>         Verify mission
      section tachikoma --verify              Auto-verify mode

    Quality:
      section quality check --op <id>    Check op quality
      section quality report --mission <id> Quest quality report

    Help:
      section <command> --help            Command help
      section medic                      System diagnostics
      section --version                   Show version

    For full documentation: https://github.com/mpurdon/gitf
    """
  end
end
