# GiTF - Architecture

## System Overview

GiTF (Ghost in the Factory) is a multi-agent orchestration system designed to operate as a "Dark Factory" for software development. It coordinates multiple AI agents (Ghosts) to autonomously plan, implement, verify, and deliver code changes with minimal human oversight.

The system leverages a **Research → Plan → Implement** pipeline, enforced by a central coordinator (Major) and a dedicated quality assurance watchdog (Tachikoma).

## Core Architecture

### Supervision Tree

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
├── GiTF.Major (GenServer - coordinator)
├── GiTF.Tachikoma (GenServer - autonomous watchdog)
└── GiTF.Dashboard.Endpoint (Phoenix - web UI)
```

### Process Communication

Agents communicate via **Links** (messages) broadcast over Phoenix PubSub.

```
                    ┌─────────────────┐
                    │  Phoenix.PubSub │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  link:major     │ │ link:ghost:123  │ │link:sector:proj │
└────────┬────────┘ └────────┬────────┘ └────────┬────────┘
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   GiTF.Major   │ │GiTF.Ghost.Worker│ │  GiTF.Sector    │
│   (GenServer)   │ │   (GenServer)   │ │   (Supervisor)  │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

## Data Model

The system uses a document-oriented approach backed by ETF (Erlang Term Format) persistence.

### Schema Entities

| Entity | Description | Key Fields |
|--------|-------------|------------|
| **Sector** | A managed git repository | `id`, `name`, `path`, `repo_url` |
| **Mission** | High-level objective | `id`, `goal`, `status`, `plan`, `current_phase` |
| **Op** | Discrete unit of work | `id`, `title`, `op_type`, `status`, `assigned_model`, `audit_status` |
| **Ghost** | Active agent instance | `id`, `name`, `status`, `context_usage`, `assigned_model` |
| **Shell** | Isolated git worktree | `id`, `worktree_path`, `branch` |
| **Link** | Inter-agent message | `id`, `from`, `to`, `subject`, `body` |

### Op Types
- **Planning**: Breaking down requirements (Model: Opus)
- **Implementation**: Writing code (Model: Sonnet)
- **Research**: Analyzing codebase (Model: Haiku)
- **Verification**: Running tests/checks (Model: Haiku)

## Autonomous Workflows ("The Dark Factory")

GiTF operates on a strict phased pipeline to ensure quality and autonomy.

### 1. Research → Plan → Implement
1.  **Research Phase**: The Major scans the codebase using cost-effective models (Haiku) to map dependencies, entry points, and constraints. This data is cached to minimize token usage.
2.  **Planning Phase**: The Major uses high-intelligence models (Opus) to decompose the Mission into a dependency graph of Ops. Each op is assigned a specific `op_type` and `audit_criteria`.
3.  **Implementation Phase**: Ghosts are spawned to execute ops in parallel. Each Ghost works in an isolated **Shell** (git worktree) to prevent conflicts.

### 2. Multi-Model Intelligence
The system dynamically selects the optimal AI model for each task to balance cost and quality:
*   **Claude 3.5 Sonnet**: Default for implementation and refactoring.
*   **Claude 3 Opus**: Used for complex planning and architectural decisions.
*   **Claude 3 Haiku**: Used for high-volume tasks like research, summarization, and verification.

### 3. Context Management
*   **Context Monitor**: Real-time tracking of token usage per Ghost.
*   **Auto-Transfer**: If a Ghost exceeds 50% context usage, it automatically summarizes its state and "transfers" to a fresh instance to prevent context window exhaustion.

### 4. Quality Assurance & Verification
The **Tachikoma** acts as an autonomous quality gatekeeper:
*   **Audit Gates**: An Op cannot be marked "Done" until it passes audit.
*   **Static Analysis**: Automated linting and code style checks.
*   **Security Scanning**: Vulnerability detection (secrets, dependencies).
*   **Performance Benchmarking**: Regression testing against baselines.
*   **Self-Healing**: The Tachikoma periodically patrols the factory to detect stuck Ghosts, deadlocks, or orphaned resources, automatically triggering recovery procedures.

## Observability

The system provides real-time visibility into the "Dark Factory" operations:

*   **TUI Dashboard**: A terminal-based UI showing active Ghosts, Missions, and system health.
*   **Metrics**: Real-time tracking of Quality Scores, Token Costs, and Failure Rates.
*   **Alerts**: Immediate notifications for stalled missions, audit failures, or budget overruns.

## Plugin System

GiTF is extensible via a behaviour-based plugin system:

*   **Models**: Adapters for AI providers (Claude, Copilot, Kimi).
*   **Commands**: Custom CLI extensions.
*   **Themes**: UI styling.

## Future Roadmap

*   **Enterprise Monitoring**: Prometheus/Grafana integration for long-term metrics history.
*   **Multi-Agent Collaboration**: Direct Ghost-to-Ghost communication for collaborative problem solving.
*   **Human-in-the-Loop**: Interactive approval gates (Override) for high-risk changes.
