# GiTF - Glossary

## Terminology Mapping

| Gas Town | The Hive | GiTF (Section 9) | Description |
|----------|----------|-------------------|-------------|
| Town | Hive | **GiTF** | Root workspace directory |
| Mayor | Queen | **Major** | AI coordinator agent |
| Rig | Comb | **Sector** | Project/repository container |
| Polecat | Bee | **Ghost** | Ephemeral worker agent |
| Bead | Job | **Op** | Single unit of work |
| Convoy | Quest | **Mission** | Bundle of related ops |
| Mail | Waggle | **Link** | Inter-agent messages |
| Hook | Cell | **Shell** | Git worktree for ghost isolation |
| Deacon | Drone | **Tachikoma** | Patrol/health monitor agent |
| Handoff | Handoff | **Transfer** | Context-preserving restart |

## Core Concepts

### GiTF (Ghost in the Factory)

Your workspace directory (e.g., `~/my-factory/`). Contains all projects, the Major, configuration, and the ETF-backed archive. One Major per workspace.

### Major

The coordinator AI agent. An AI instance with full context about your workspace. Start here — tell the Major what you want to accomplish and it will create ops and spawn ghosts.

### Sector

A project container. Each sector wraps a git repository and manages its associated ghosts. Multiple sectors can exist in one workspace.

### Ghost

An ephemeral worker agent. Spawns to complete a single op, then disappears. Each ghost runs in its own git worktree (shell) for isolation. Named after the operatives in Ghost in the Shell.

### Op

A discrete unit of work. Created by the Major, assigned to a ghost. Examples: "Implement login endpoint", "Add OAuth provider", "Write tests for auth module".

### Mission

A bundle of related ops. When you tell the Major "Build user authentication", it creates a mission containing multiple ops that together accomplish the goal.

### Link

The messaging system. Inter-agent communication channels. Ghosts and the Major exchange links to coordinate work, report progress, and handle issues.

### Shell

A git worktree where a ghost does its work. Provides isolation so multiple ghosts can work on the same sector without conflicts. Cleaned up when the ghost completes. The shell is the vessel the ghost inhabits.

### Tachikoma

A patrol agent that monitors factory health. Checks for stuck ghosts, orphaned shells, and other issues. Named after the think-tanks from Ghost in the Shell.

## Workflow Terms

### Brief

The context injection that happens when an AI session starts. The `gitf brief` command outputs role-specific context that the AI captures.

### Transfer

When a ghost's context window fills up, it can "transfer" to a fresh session. State is serialized, sent as a link to itself, and restored in the new session.

### Transcript

The AI's conversation log. GiTF watches transcript files to track token usage and costs.

## Additional Concepts

| Concept | Name | Description |
|---------|------|-------------|
| Permissions | **Clearance** | Graduated permission levels for ghosts |
| Trust scoring | **Trust** | Model reliability tracking |
| Approval gates | **Override** | Human-in-the-loop approval for high-risk changes |
| Path protection | **Barrier** | Path traversal and scope protection |
| Learning | **Intel** | Pattern learning from past operations |
| Identity | **GhostID** | Operative identity and agent profiles |
| Autonomy limits | **Limiter** | Ghost autonomy constraints |
| Reconnaissance | **Recon** | Read-only codebase exploration |
| Diagnostics | **Medic** | System health diagnostics |
| Quality check | **Audit** | Post-op verification |
| Post-op review | **Debrief** | Post-operation review |
| State snapshot | **Backup** | Ghost state checkpointing |
| Code integration | **Sync** | Branch merging and code integration |
| Shutdown | **Exfil** | Graceful shutdown procedures |

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
