# GiTF — Ghost in the Factory, Section 9

Multi-agent orchestration system for AI coding assistants. Coordinate multiple AI instances working on a shared codebase with automatic task delegation, isolated git worktrees, inter-agent messaging, cost tracking, and a real-time web dashboard.

**Status: Dark Factory Complete (98%)** - Fully autonomous operation with self-healing, quality assurance, and intelligent model selection.

Supports multiple model providers through a plugin system: Claude Code, GitHub Copilot CLI, Kimi CLI, and any future provider via the `GiTF.Plugin.Model` behaviour.

Built in Elixir, leveraging OTP supervision trees for process management, Phoenix PubSub for messaging, and an ETF-backed archive for persistence.

## Getting Started

### 1. Install prerequisites

You need three things on your machine:

| Dependency | Version | Install |
|------------|---------|---------|
| **Elixir** | 1.15+ | `brew install elixir` or [elixir-lang.org/install](https://elixir-lang.org/install.html) |
| **Git** | 2.25+ | `brew install git` or [git-scm.com](https://git-scm.com) |
| **AI CLI** | latest | At least one: `claude`, `copilot`, or `kimi` |

Verify everything is ready:

```bash
elixir --version   # should print 1.15+
git --version      # should print 2.25+

# At least one of these:
claude --version   # Claude Code CLI
copilot --version  # GitHub Copilot CLI
kimi --version     # Kimi CLI
```

### 2. Build the GiTF CLI

```bash
git clone git@github.com:mpurdon/gitf.git
cd gitf
mix deps.get
mix escript.build
```

This produces a `./gitf` binary. Optionally move it to your PATH:

```bash
cp gitf /usr/local/bin/
```

### 3. Create a workspace

The quickest way -- auto-discovers any git repos in the target directory:

```bash
gitf init ~/my-factory --quick
```

Or step by step:

```bash
gitf init ~/my-factory
cd ~/my-factory
gitf sector add /path/to/your/repo --name myproject
```

### 4. Start the Major

```bash
cd ~/my-factory
gitf major
```

Tell the Major what you want built. It will analyze your request, break it into ops, spawn ghosts (parallel AI instances), and coordinate them to completion.

### 5. Monitor progress

```bash
gitf                    # Launch the interactive "Dark Factory" Dashboard (TUI)
gitf watch              # Live terminal progress (simple view)
gitf mission list       # See active missions
gitf ghost list         # See running ghosts
gitf costs summary      # Check token spend
gitf dashboard          # Web UI at localhost:4040 (legacy)
```

Run `gitf medic` at any time to verify your system health.

## "Dark Factory" Capabilities

GiTF operates autonomously to deliver high-quality code:

*   **Research → Plan → Implement**: A structured pipeline ensures thoughtful execution.
*   **Multi-Model Intelligence**: Dynamically selects the best AI model (Opus vs Sonnet vs Haiku) for each task to balance cost and quality.
*   **Context Management**: Automatically monitors token usage and "transfers" work to fresh agents before context limits are reached.
*   **Autonomous Quality Assurance**: The **Tachikoma** watchdog continuously verifies work, running tests and checks before marking ops as complete.
*   **Self-Healing**: Detects and recovers from stuck processes, deadlocks, and orphaned resources automatically.

## Model Providers

GiTF uses a plugin system to support multiple AI model providers. The active provider is resolved per-session via config or CLI flags.

| Provider | Binary | Streaming | Cost Tracking | Session Resume |
|----------|--------|-----------|---------------|----------------|
| **Claude Code** | `claude` | JSONL | Yes | Yes |
| **Copilot CLI** | `copilot` | Plain text | No (subscription) | No |
| **Kimi CLI** | `kimi` | JSONL | Yes | Yes |

Set the default provider in `.gitf/config.toml`:

```toml
[plugins.models]
default = "claude"   # or "copilot" or "kimi"
```

## CLI Reference

### Workspace

```bash
gitf init [PATH] [--quick] [--force]   # Initialize a workspace
gitf medic [--fix]                      # Run health checks
gitf                                    # Start interactive TUI dashboard
gitf watch                              # Live progress monitor
gitf version                            # Print version
```

### Projects (Sectors)

```bash
gitf sector add <path> [--name NAME]    # Register a git repo
  [--sync-strategy manual|auto_merge|pr_branch]
  [--validation-command "mix test"]
  [--github-owner OWNER] [--github-repo REPO]
gitf sector list                        # List registered projects
gitf sector remove <name>               # Unregister a project
gitf sector rename <old> <new>          # Rename a sector
```

### Orchestration

```bash
gitf major                              # Start Major coordinator session
gitf ghost list                         # List all ghosts
gitf ghost spawn --op ID --sector ID    # Spawn a worker ghost
gitf ghost stop --id ID                 # Stop a running ghost
gitf ghost revive --id ID               # Revive a dead ghost's worktree
gitf ghost done --id ID                 # Mark a ghost as completed
gitf ghost fail --id ID --reason "..."  # Mark a ghost as failed
```

### Work Tracking

```bash
gitf mission new <name>                 # Create a mission
gitf mission list                       # List missions
gitf mission show <id>                  # Show mission details with ops

gitf ops list                           # List all ops
gitf ops show <id>                      # Show op details
gitf ops create --mission ID --title T --sector ID  # Create an op
```

### Op Dependencies

```bash
gitf ops deps add --op ID --depends-on ID    # Add dependency
gitf ops deps remove --op ID --depends-on ID # Remove dependency
gitf ops deps list --op ID                   # Show dependencies
```

### Messaging (Links)

```bash
gitf link list [--to RECIPIENT]         # List messages
gitf link show <id>                     # Read a message
gitf link send -f FROM -t TO -s SUBJ -b BODY  # Send a message
```

### Cost Tracking

```bash
gitf costs summary                      # Aggregate cost report
gitf costs record --ghost ID --input N --output N  # Record costs manually
gitf budget --mission ID                # Check mission budget status
```

### Git Worktrees (Shells)

```bash
gitf shell list                         # List active worktrees
gitf shell clean                        # Remove orphaned worktrees
```

### Advanced

```bash
gitf brief --major                      # Output Major context prompt
gitf brief --ghost <id>                 # Output Ghost context prompt
gitf transfer create --ghost ID         # Create context-preserving transfer
gitf transfer show --ghost ID           # Show transfer context
gitf conflict check [--ghost ID]        # Check for merge conflicts
gitf audit --ghost ID                   # Validate a ghost's completed work
gitf tachikoma [--no-fix]               # Start health patrol
```

### Plugins

```bash
gitf plugin list                        # List loaded plugins
gitf plugin load <path>                 # Load a plugin from file
gitf plugin unload <type> <name>        # Unload a plugin
gitf plugin reload <type> <name>        # Hot-reload a plugin
```

### GitHub Integration

```bash
gitf github pr --ghost ID              # Create PR for a ghost's work
gitf github issues --sector ID         # List issues for a project
gitf github sync --sector ID           # Sync GitHub issues
```

## Configuration

The config lives at `.gitf/config.toml`:

```toml
[gitf]
version = "0.1.0"

[major]
max_ghosts = 5

[costs]
warn_threshold_usd = 5.0
budget_usd = 10.0

[plugins.models]
default = "claude"

[github]
token = ""
```

You can also set the `GITF_PATH` environment variable to point to your workspace from anywhere.

## Development

```bash
# Run tests
mix test

# Run tests (excluding e2e)
mix test --exclude e2e

# Format code
mix format

# Build escript
MIX_ENV=prod mix escript.build
```

## Further Reading

- [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) -- Detailed system design, workflows, and schema.
- [`specs/GLOSSARY.md`](specs/GLOSSARY.md) -- Full terminology reference.
- [`specs/DELEGATION.md`](specs/DELEGATION.md) -- Major delegation principle and enforcement.

## License

MIT
