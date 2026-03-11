# GiTF — Ghost in the Factory, Section 9

**Multi-agent orchestration system for AI coding assistants with persistent work tracking**

## Quick Start

```bash
gitf init ~/my-factory --git
cd ~/my-factory
gitf sector add myproject https://github.com/you/repo.git
gitf major
```

Then tell the Major what you want to build!

## Overview

GiTF is a workspace manager that coordinates multiple AI coding agents working on different tasks. Built in Elixir, it leverages OTP patterns for process supervision, Phoenix PubSub for messaging, and an ETF-backed archive for persistence.

Supports multiple model providers through a plugin system: Claude Code, GitHub Copilot CLI, Kimi CLI, and any custom provider via the `GiTF.Plugin.Model` behaviour.

## Core Concepts

| Concept | Name | Description |
|---------|------|-------------|
| Workspace | **GiTF** | Root directory, one Major |
| Coordinator | **Major** | AI that orchestrates work |
| Project | **Sector** | Git repo container |
| Worker agent | **Ghost** | Ephemeral AI instance |
| Work unit | **Op** | Single task for a ghost |
| Work bundle | **Mission** | Group of related ops |
| Messages | **Link** | Inter-agent communication |
| Persistent state | **Shell** | Git worktree for ghost's work |

## Architecture

```
GiTF.Application (OTP App)
├── GiTF.Archive (ETF-backed persistence)
├── Phoenix.PubSub (inter-agent messaging)
├── Registry (process registry)
├── GiTF.Plugin.Manager (plugin lifecycle + hot reload)
│   ├── GiTF.Plugin.Registry (ETS-backed lookup)
│   ├── GiTF.Plugin.MCPSupervisor
│   └── GiTF.Plugin.ChannelSupervisor
├── GiTF.SectorSupervisor (DynamicSupervisor)
│   └── GiTF.Sector (per-project supervisor)
│       ├── GiTF.Ghost.Worker (GenServer per worker)
│       └── GiTF.TranscriptWatcher (file watcher)
├── GiTF.Major (GenServer - started on demand)
├── GiTF.Tachikoma (GenServer - health monitor)
└── GiTF.Dashboard.Endpoint (Phoenix - web UI)
```

## Workflow

```
You → gitf major
        "Build user authentication system"
        ↓
      Major creates ops:
        - op-a1b2: "Create user model"
        - op-c3d4: "Implement login endpoint"
        - op-e5f6: "Add session management"
        ↓
      Major spawns ghosts, assigns ops
        ↓
      Ghosts complete work, Major tracks progress
        ↓
      You see: "Auth system complete, 3/3 ops done"
```

## Model Providers

| Provider | Streaming | Cost Tracking | Session Resume |
|----------|-----------|---------------|----------------|
| Claude Code | JSONL | Yes | Yes |
| Copilot CLI | Plain text | No | No |
| Kimi CLI | JSONL | Yes | Yes |

Configure the default in `.gitf/config.toml`:

```toml
[plugins.models]
default = "claude"
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `gitf init` | Initialize a new workspace |
| `gitf major` | Start Major session |
| `gitf sector add` | Add a project |
| `gitf sector list` | List projects |
| `gitf sector rename` | Rename a sector |
| `gitf mission list` | Show missions |
| `gitf mission show` | Mission details |
| `gitf ghosts` | List active ghosts |
| `gitf ghost revive` | Revive a dead ghost |
| `gitf link list` | Check messages |
| `gitf costs` | Token costs |
| `gitf medic` | Health checks |
| `gitf dashboard` | Web UI |
| `gitf plugin list` | List plugins |
| `gitf watch` | Live progress |

## Dependencies

- Elixir 1.15+
- Git 2.25+ (for worktree support)
- At least one AI CLI: `claude`, `copilot`, or `kimi`

## License

MIT
