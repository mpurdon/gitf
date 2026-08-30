defmodule GiTF.MCPServer.Tools do
  @moduledoc "MCP tool definitions with JSON Schema input specs."

  def all do
    [
      %{
        name: "factory_status",
        description:
          "Overview of the entire factory: active missions, running ghosts, cost summary, and system health.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "host_stats",
        description:
          "Host vitals: memory (with swap and a headroom verdict), CPU load per core, " <>
            "uptime, network interfaces, and the BEAM's own footprint.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "disk_usage",
        description:
          "Disk-usage report: filesystem totals, gitf's infra dirs (build caches, store), " <>
            "and per-sector/per-ghost/per-mission worktree attribution.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "list_missions",
        description: "List missions. Defaults to active missions only.",
        inputSchema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              description: "Filter by status (pending, active, completed, closed, killed)"
            },
            all: %{
              type: "boolean",
              description: "Include completed/closed missions",
              default: false
            }
          }
        }
      },
      %{
        name: "show_mission",
        description: "Get detailed info about a specific mission, including its ops.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Mission ID"}},
          required: ["id"]
        }
      },
      %{
        name: "list_ops",
        description: "List ops (units of work). Defaults to active ops only.",
        inputSchema: %{
          type: "object",
          properties: %{
            mission_id: %{type: "string", description: "Filter by mission ID"},
            status: %{type: "string", description: "Filter by status"},
            all: %{type: "boolean", description: "Include done/failed ops", default: false}
          }
        }
      },
      %{
        name: "show_op",
        description: "Get detailed info about a specific op.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Op ID"}},
          required: ["id"]
        }
      },
      %{
        name: "list_ghosts",
        description: "List ghost agents. Defaults to active ghosts only.",
        inputSchema: %{
          type: "object",
          properties: %{
            status: %{type: "string", description: "Filter by status"},
            all: %{type: "boolean", description: "Include stopped/crashed ghosts", default: false}
          }
        }
      },
      %{
        name: "list_sectors",
        description: "List registered sectors (git repositories).",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "costs_summary",
        description:
          "Get cost breakdown by model, ghost, and category. Shows total tokens and USD spent.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "ledger_stats",
        description:
          "Orchestration stats by pipeline mode (fast/full): success rate, avg duration, avg cost, rework rate, phase durations.",
        inputSchema: %{
          type: "object",
          properties: %{
            mode: %{
              type: "string",
              description: "Filter by mode: 'fast' or 'full'. Omit for all."
            }
          }
        }
      },
      %{
        name: "provider_perf",
        description:
          "Per provider+model performance over a window: p50/p95 call duration, p50 TTFT " <>
            "(nil until a path streams — nothing does today), mean output tokens/sec, " <>
            "cold-start rate (gap > 5min AND duration > 3x that pair's median), error rate, " <>
            "and $/1M effective tokens (input + output + 10% of cache reads, joined from " <>
            "costs). Plus mission wall-clock p50/p95 by pipeline mode, measured start " <>
            "transition to terminal transition with queue wait separated out. The baseline " <>
            "table for evaluating a serverless-provider migration.",
        inputSchema: %{
          type: "object",
          properties: %{
            hours: %{
              type: "integer",
              description: "Window in hours (default 168 — the costs retention)",
              default: 168
            }
          }
        }
      },
      %{
        name: "show_artifact",
        description:
          "Get a phase artifact for a mission (research, requirements, design, planning, validation, sync, scoring). Shows the actual output from that phase.",
        inputSchema: %{
          type: "object",
          properties: %{
            mission_id: %{type: "string", description: "Mission ID"},
            phase: %{
              type: "string",
              description:
                "Phase name: research, requirements, design, planning, validation, sync, scoring"
            }
          },
          required: ["mission_id", "phase"]
        }
      },
      %{
        name: "ghost_output",
        description:
          "Get the output summary for a ghost's op. Shows what the ghost actually produced (last 20 lines of output).",
        inputSchema: %{
          type: "object",
          properties: %{
            op_id: %{type: "string", description: "Op ID"}
          },
          required: ["op_id"]
        }
      },
      %{
        name: "mission_diagnosis",
        description:
          "Comprehensive diagnostic for a mission: phase artifacts, validation results, sync status, error details, fix loop history. Use this to understand why a mission failed or stalled.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"}
          },
          required: ["id"]
        }
      },
      %{
        name: "list_links",
        description: "List inter-agent messages (links) between the Major and ghosts.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "Filter by recipient"},
            from: %{type: "string", description: "Filter by sender"},
            limit: %{type: "integer", description: "Max messages to return", default: 20}
          }
        }
      },
      %{
        name: "mission_report",
        description:
          "Generate a formatted performance report for a mission (timing, tokens, cost, output).",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Mission ID"}},
          required: ["id"]
        }
      },
      %{
        name: "health_check",
        description:
          "Run system health checks (pubsub, store, disk, memory, model API, git, major).",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "mission_timeline",
        description:
          "Get the full chronological event timeline for a mission. Shows every spawn, completion, failure, merge, and phase transition. Essential for diagnosing what went wrong.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            limit: %{
              type: "integer",
              description: "Max events to return (default 50)",
              default: 50
            }
          },
          required: ["id"]
        }
      },
      # -- Write operations (require confirm: true) ----------------------------
      %{
        name: "create_mission",
        description:
          "[WRITE] Create a new mission with a goal. Optionally assign to a sector. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            goal: %{type: "string", description: "The mission objective"},
            sector_id: %{type: "string", description: "Sector to assign the mission to"},
            name: %{
              type: "string",
              description: "Human-friendly mission name (auto-generated if omitted)"
            },
            review_plan: %{
              type: "boolean",
              description: "Pause at planning phase for manual review in the dashboard",
              default: false
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["goal", "confirm"]
        }
      },
      %{
        name: "resume_mission",
        description:
          "[WRITE] Start a NEW mission on a failed mission's preserved tree, re-entering at " <>
            "from_phase instead of running the pipeline from the top. Phases before from_phase " <>
            "are inherited from the parent (artifacts stamped inherited_from) and their " <>
            "transitions are replayed in the timeline. Requires an archive/<parent_id> branch " <>
            "in the sector clone. Resume IMPLIES start — do not call start_mission after. " <>
            "Inherited state is a suspect in every failure of a resumed run: if the resumed run " <>
            "fails in a way that could implicate the inherited design, plan or tree, run the " <>
            "mission fresh instead of resuming again. Returns IMMEDIATELY: the worktree is " <>
            "seeded in the background, so the mission comes back status \"pending\" with " <>
            "resume_seeding true — poll show_mission until it is \"active\". One live resume " <>
            "per parent: calling again returns the existing child with already_resumed true " <>
            "and creates nothing. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "The FAILED or killed parent mission's ID"},
            from_phase: %{
              type: "string",
              description:
                "Phase to re-enter at. Only \"validation\" (the endgame-iteration loop) " <>
                  "is supported today.",
              default: "validation"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "create_project",
        description:
          "[WRITE] Create a draft project: a multi-mission initiative with a brief and a dependency-DAG roadmap. " <>
            "Aramaki turns roadmap items into missions in dependency order once the project is approved. " <>
            "Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Project name"},
            brief: %{
              type: "object",
              description:
                "Planning brief: vision (string), constraints/decisions/open_questions (string arrays)"
            },
            roadmap: %{
              type: "array",
              description: "Roadmap items (the dependency DAG)",
              items: %{
                type: "object",
                properties: %{
                  id: %{type: "string", description: "Stable item id (auto-generated if omitted)"},
                  title: %{type: "string", description: "Short item title"},
                  goal: %{
                    type: "string",
                    description: "Full mission goal text for an AI agent to execute"
                  },
                  depends_on: %{
                    type: "array",
                    items: %{type: "string"},
                    description: "Ids of items that must complete first"
                  }
                },
                required: ["title", "goal"]
              }
            },
            sector_id: %{
              type: "string",
              description: "Target sector (may be set at approval instead)"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["name", "roadmap", "confirm"]
        }
      },
      %{
        name: "list_projects",
        description:
          "[READ] List projects (optionally by status: draft|active|paused|completed|failed).",
        inputSchema: %{
          type: "object",
          properties: %{status: %{type: "string", description: "Filter by status"}}
        }
      },
      %{
        name: "show_project",
        description:
          "[READ] Show a project: brief, roadmap DAG with per-item status and mission ids.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Project ID"}},
          required: ["id"]
        }
      },
      %{
        name: "approve_project",
        description:
          "[WRITE] Approve a draft project so Aramaki starts running it. Optionally assign an existing " <>
            "sector (sector_id) or create a greenfield one (create_sector). Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Project ID"},
            sector_id: %{type: "string", description: "Existing sector to run in"},
            create_sector: %{
              type: "string",
              description: "Name for a new empty sector (git init) to run in"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "update_project_roadmap",
        description:
          "[WRITE] Replace a DRAFT project's roadmap (same item shape as create_project). Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Project ID"},
            roadmap: %{
              type: "array",
              description: "Replacement roadmap items",
              items: %{type: "object"}
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "roadmap", "confirm"]
        }
      },
      %{
        name: "pause_project",
        description:
          "[WRITE] Pause an active project (no new missions created). Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Project ID"},
            reason: %{type: "string", description: "Why (recorded on the project)"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "resume_project",
        description: "[WRITE] Resume a paused project. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Project ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "start_mission",
        description:
          "[WRITE] Start a mission (or restart a stalled one). Kicks off the phase pipeline " <>
            "from triage, which infers a pipeline mode unless one is forced here. " <>
            "Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            fast: %{
              type: "boolean",
              description:
                "Force the streamlined pipeline: single design strategy, review " <>
                  "auto-approved. Sticky — triage cannot revise it.",
              default: false
            },
            full: %{
              type: "boolean",
              description:
                "Force the full pipeline: every phase runs (triage's skip flags are " <>
                  "overridden) and design produces competing strategies. Sticky — " <>
                  "triage cannot revise it. Omit both flags and triage decides from " <>
                  "complexity.",
              default: false
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "kill_mission",
        description:
          "[WRITE] Kill a mission and all its ops/ghosts. This is destructive. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "close_mission",
        description:
          "[WRITE] Close a completed mission and clean up its shells. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "delete_mission",
        description:
          "[WRITE] Permanently delete a mission record. This is destructive and irreversible. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "show_approval",
        description:
          "The approval decision for a mission, triaged. Returns the pending approval " <>
            "request (requested_at, risk level), the timeout state (hours configured, " <>
            "awake hours elapsed, whether auto-approve is even possible at this risk " <>
            "level), and the full triage from GiTF.Approval.Triage — fails / concerns / " <>
            "oks, each item carrying status, kind, title, detail and any rebuttal. The " <>
            "Catwalk's approval panel derives from the same module, so the two surfaces " <>
            "cannot disagree. Answers for approved and rejected missions too (see " <>
            "approval_status). Read this BEFORE approve_mission: a pass verdict with " <>
            "concerns is exactly where a false pass hides.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"}
          },
          required: ["id"]
        }
      },
      %{
        name: "approve_mission",
        description:
          "[WRITE] Approve a mission waiting at awaiting_approval, clearing the gate so " <>
            "the merge/PR proceeds. Only acts on a PENDING approval — an already-decided " <>
            "mission comes back with approved: false and its current approval_status " <>
            "rather than an error. If the triage reports any FAILING checks the approval " <>
            "still goes through (the operator outranks the machine) but the response " <>
            "leads with a warning naming them. Recorded as approved_by \"mcp_operator\" — " <>
            "the MCP has no person-level identity, and unlike an auto_* approval this " <>
            "counts as a human decision and clears the phase gate. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            notes: %{
              type: "string",
              description: "Optional note recorded on the approval artifact and audit log"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "reject_mission",
        description:
          "[WRITE] Reject a mission waiting at awaiting_approval. The rejection is " <>
            "recorded immediately; the mission terminal-fails on the next advance sweep, " <>
            "and its tree survives as the archive/<id> branch so resume_mission can still " <>
            "reach it. The reason is stored on the approval artifact and the audit log " <>
            "but NO ghost consumes it today — rejecting does not schedule a fix, so say " <>
            "what is wrong for the human who reads it next. Only acts on a PENDING " <>
            "approval. Recorded as rejected_by \"mcp_operator\". Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            reason: %{
              type: "string",
              description: "Why it is rejected (required, non-empty) — recorded, not acted on"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "reason", "confirm"]
        }
      },
      %{
        name: "list_questions",
        description:
          "Open operator questions — missions holding at awaiting_input because a phase hit " <>
            "a decision only you can make. Each entry carries the mission, the phase that " <>
            "asked, the kind (choice/text/confirm), the prompt, the options with their " <>
            "rationale, and how long it has been waiting in AWAKE hours. Oldest first: the " <>
            "one that has been holding longest is costing the most wall clock. Optional " <>
            "mission_id narrows it to one mission, and answered: true includes decided ones. " <>
            "A held mission NEVER auto-answers and never times out — it waits until you " <>
            "answer or kill it, so an empty list here is the only proof nothing is stuck " <>
            "on you.",
        inputSchema: %{
          type: "object",
          properties: %{
            mission_id: %{
              type: "string",
              description: "Only questions for this mission (optional)"
            },
            answered: %{
              type: "boolean",
              description: "Include already-answered questions (default false)"
            }
          },
          required: []
        }
      },
      %{
        name: "show_question",
        description:
          "One question in full: prompt, kind, every option with its id, label and " <>
            "rationale, the mission's goal and current phase, the phase that asked, the " <>
            "budget remaining on that mission, and — once decided — the answer, who gave " <>
            "it and when. Read this before answer_question: the option id, not the label, " <>
            "is what answer_question takes for a :choice.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Question ID (inq-…)"}
          },
          required: ["id"]
        }
      },
      %{
        name: "answer_question",
        description:
          "[WRITE] Answer an open question, releasing the mission. It transitions back to " <>
            "the phase that asked and RE-RUNS it with your answer in the prompt, so the " <>
            "answer shapes what gets built rather than being filed next to it. For a " <>
            ":choice pass answer as the option id (an unknown id is refused, with the valid " <>
            "ids listed); for :confirm pass true/false; for :text pass the text. Answering " <>
            "is idempotent and the FIRST answer wins: an already-answered question comes " <>
            "back answered: false with the standing decision rather than an error, because " <>
            "work has already been re-dispatched against it. Recorded as answered_by " <>
            "\"mcp_operator\" — the MCP has no person-level identity. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Question ID (inq-…)"},
            answer: %{
              description: "Option id for :choice, true/false for :confirm, the text for :text",
              type: ["string", "boolean"]
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "answer", "confirm"]
        }
      },
      %{
        name: "set_approval_timeout",
        description:
          "[WRITE] Set the auto-approve timeout (hours) for pending approvals — config " <>
            "path [approvals] timeout_hours, factory-wide, not per sector. Elapsed time " <>
            "is AWAKE time, so an idle-stopped box does not burn the window. Critical-risk " <>
            "missions never auto-approve regardless. Persisted to the config file the " <>
            "factory reads and reloaded in place — no restart, survives one. The response " <>
            "echoes the EFFECTIVE value re-read after the reload, which can differ from " <>
            "what you asked for if a HIVE_* env var outranks the file. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            hours: %{
              type: "number",
              description: "Timeout in hours (greater than 0, up to 720)"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["hours", "confirm"]
        }
      },
      %{
        name: "reset_op",
        description:
          "[WRITE] Reset a failed or stuck op so it can be retried. Stops its ghost and cleans up its shell. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Op ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "kill_op",
        description: "[WRITE] Kill an op and stop its ghost. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Op ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "stop_ghost",
        description: "[WRITE] Stop a running ghost agent. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Ghost ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "send_link",
        description: "[WRITE] Send an inter-agent message (link). Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            from: %{type: "string", description: "Sender ID (e.g. 'major' or a ghost ID)"},
            to: %{type: "string", description: "Recipient ID"},
            subject: %{type: "string", description: "Message subject"},
            body: %{type: "string", description: "Message body"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["from", "to", "subject", "body", "confirm"]
        }
      },
      %{
        name: "test_provider",
        description:
          "Test an LLM provider connection using the same code path ghosts use. " <>
            "Sends 'Say OK' via ReqLLM or BedrockDirect and verifies the response has content. " <>
            "Returns latency on success or diagnostic details on failure.",
        inputSchema: %{
          type: "object",
          properties: %{
            provider: %{
              type: "string",
              description: "Provider name: google, bedrock, anthropic, openai, etc."
            },
            all: %{type: "boolean", description: "Test ALL configured providers", default: false}
          }
        }
      },
      %{
        name: "circuit_status",
        description:
          "Return per-provider circuit breaker state (closed/open/half_open), failure count, " <>
            "last failure reason, and (for open circuits) failure mode + seconds until next probe. " <>
            "Unlike test_provider, this reflects what ghosts actually experience via ProviderCircuit.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "circuit_reset",
        description:
          "[WRITE] Manually reset a provider's circuit breaker to closed. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            provider: %{type: "string", description: "Provider name (e.g. 'google', 'bedrock')"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["provider", "confirm"]
        }
      },
      %{
        name: "set_sync_strategy",
        description:
          "[WRITE] Set a sector's sync strategy. " <>
            "auto_merge: merge ghost branches directly into main (no PR). " <>
            "pr_branch: merge into a mission branch + open a PR in the publish phase. " <>
            "manual: leave branches alone for the human to merge.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            strategy: %{
              type: "string",
              enum: ["auto_merge", "pr_branch", "manual"],
              description: "Sync strategy"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["sector_id", "strategy", "confirm"]
        }
      },
      %{
        name: "set_validation_timeout",
        description:
          "[WRITE] Override a sector's validation deadline (ms). The budget is normally " <>
            "DERIVED — onboarding detects the stack and migration 9 backfilled existing " <>
            "sectors — so this is the escape hatch, not the mechanism. Every runner " <>
            "(validator, audit, merge resolution, regression checks) honours the same " <>
            "value; a too-small budget reports healthy work as timeouts and manufactures " <>
            "fix ghosts for defects that do not exist. Pass clear: true to remove the " <>
            "override and fall back to the 120s default. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            timeout_ms: %{
              type: "integer",
              description: "Deadline in milliseconds (1_000..1_800_000)"
            },
            clear: %{
              type: "boolean",
              description: "Remove the override instead of setting one",
              default: false
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["sector_id", "confirm"]
        }
      },
      %{
        name: "list_skills",
        description:
          "List skills in the self-improving skill library. Filter by scope (global/sector) or sector_id.",
        inputSchema: %{
          type: "object",
          properties: %{
            scope: %{type: "string", enum: ["global", "sector"], description: "Filter by scope"},
            sector_id: %{
              type: "string",
              description: "Filter by sector (only meaningful with scope=sector)"
            },
            include_archived: %{
              type: "boolean",
              description: "Include archived skills",
              default: false
            }
          }
        }
      },
      %{
        name: "show_skill",
        description: "Get the full body + stats for a single skill.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Skill ID"}},
          required: ["id"]
        }
      },
      %{
        name: "update_skill",
        description:
          "[WRITE] Manually edit a skill's description, body, or status. Use to operator-override auto-drafted skills or archive/unarchive.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Skill ID"},
            name: %{type: "string", description: "New name (optional)"},
            description: %{type: "string", description: "New description (optional)"},
            body: %{type: "string", description: "New body (optional)"},
            status: %{
              type: "string",
              enum: ["active", "archived"],
              description: "New status (optional)"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "delete_skill",
        description:
          "[WRITE] Permanently delete a skill. Prefer archive (via update_skill status=archived) over delete; delete is for low-quality auto-drafts.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Skill ID"},
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["id", "confirm"]
        }
      },
      %{
        name: "skills_stats",
        description:
          "Aggregate stats for the skill library: counts by scope/source, top-applied skills, flagged low-utility skills.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{
              type: "string",
              description: "Scope stats to a specific sector (optional)"
            }
          }
        }
      },
      %{
        name: "list_outcomes",
        description:
          "List post-completion outcome records for missions whose PRs are being (or were) tracked. Filter by mission_id, category, or include stopped.",
        inputSchema: %{
          type: "object",
          properties: %{
            mission_id: %{type: "string", description: "Filter to one mission"},
            category: %{
              type: "string",
              enum: [
                "pending",
                "merged_clean",
                "merged_reverted",
                "closed_unmerged",
                "changes_requested",
                "stale",
                "merged_broke_main"
              ],
              description: "Filter by outcome category"
            },
            include_stopped: %{
              type: "boolean",
              description: "Include records where tracking has been stopped",
              default: true
            }
          }
        }
      },
      %{
        name: "refresh_outcome",
        description:
          "Poll a tracked PR now instead of waiting for its scheduled slot. Use when you have just left a review and want the factory to see it immediately. Identify the outcome by id, mission_id, or pr_url.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Outcome ID"},
            mission_id: %{type: "string", description: "Mission that opened the PR"},
            pr_url: %{type: "string", description: "Full pull request URL"}
          }
        }
      },
      %{
        name: "idle_stop_override",
        description:
          "Temporarily change how long the box tolerates being idle before powering itself off. Requires BOTH a new threshold and a duration — e.g. idle_minutes 60 for duration_minutes 240 means 'for the next 4 hours, wait an hour of idleness before stopping'. Pass clear:true to restore the default immediately. Overrides always expire; there is no permanent hold.",
        inputSchema: %{
          type: "object",
          properties: %{
            idle_minutes: %{
              type: "integer",
              description: "Idle minutes to tolerate while the override is active (max 720)"
            },
            duration_minutes: %{
              type: "integer",
              description: "How long the override itself lasts (max 1440)"
            },
            reason: %{type: "string", description: "Why — shown when the override is inspected"},
            clear: %{type: "boolean", description: "Remove any active override", default: false}
          }
        }
      },
      %{
        name: "show_outcome",
        description:
          "Full detail for a single outcome record — PR state, review history, poll timeline, category.",
        inputSchema: %{
          type: "object",
          properties: %{id: %{type: "string", description: "Outcome ID"}},
          required: ["id"]
        }
      },
      %{
        name: "outcomes_stats",
        description:
          "Aggregate outcome stats: merge-success rate per sector, category distribution, PRs currently tracking, validator calibration.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{
              type: "string",
              description: "Scope stats to a specific sector (optional)"
            }
          }
        }
      },
      %{
        name: "autonomy_tier",
        description:
          "Read the current autonomy tier (trusted/normal/require_approval) derived from merge outcomes for a sector.",
        inputSchema: %{
          type: "object",
          properties: %{sector_id: %{type: "string", description: "Sector ID"}},
          required: ["sector_id"]
        }
      },
      %{
        name: "lsp_definition",
        description:
          "Find the definition(s) of the symbol at file:line:character within a sector. Returns LSP Location list. Lazily starts the language server for the sector on first call.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID (workspace)"},
            file_path: %{type: "string", description: "Absolute path to the source file"},
            line: %{type: "integer", description: "0-indexed line"},
            character: %{type: "integer", description: "0-indexed column"}
          },
          required: ["sector_id", "file_path", "line", "character"]
        }
      },
      %{
        name: "lsp_references",
        description:
          "Find references to the symbol at file:line:character within a sector. include_declaration controls whether the declaration itself is included.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            file_path: %{type: "string", description: "Absolute path to the source file"},
            line: %{type: "integer", description: "0-indexed line"},
            character: %{type: "integer", description: "0-indexed column"},
            include_declaration: %{
              type: "boolean",
              description: "Include the declaration (default false)"
            }
          },
          required: ["sector_id", "file_path", "line", "character"]
        }
      },
      %{
        name: "lsp_hover",
        description:
          "Hover info (signature/docstring) for the symbol at file:line:character within a sector.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            file_path: %{type: "string", description: "Absolute path to the source file"},
            line: %{type: "integer", description: "0-indexed line"},
            character: %{type: "integer", description: "0-indexed column"}
          },
          required: ["sector_id", "file_path", "line", "character"]
        }
      },
      %{
        name: "lsp_diagnostics",
        description:
          "Cached compile/lint diagnostics for a file in a sector. Opens the file with the language server if it isn't already open. Diagnostics arrive asynchronously after didOpen — first call may return [] until the server finishes analysis (ElixirLS cold start can take 5-30s).",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            file_path: %{type: "string", description: "Absolute path to the source file"}
          },
          required: ["sector_id", "file_path"]
        }
      },
      %{
        name: "lsp_document_symbol",
        description:
          "File symbol outline (hierarchical: modules, functions, types). Useful as prompt context when planning edits.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            file_path: %{type: "string", description: "Absolute path to the source file"}
          },
          required: ["sector_id", "file_path"]
        }
      },
      %{
        name: "lsp_workspace_symbol",
        description:
          "Workspace-wide symbol search by name (modules, functions, types matching `query`). Complements lsp_definition (which needs a position) — find by name.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            query: %{type: "string", description: "Symbol name fragment"}
          },
          required: ["sector_id", "query"]
        }
      },
      %{
        name: "lsp_code_action",
        description:
          "Available code actions (quick fixes, refactors) for a range in a file. Returns the action list; nothing is applied automatically. Use lsp_apply_code_action with one of the returned actions to apply its edit.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            file_path: %{type: "string", description: "Absolute path to the source file"},
            start_line: %{type: "integer", description: "0-indexed start line"},
            start_character: %{type: "integer", description: "0-indexed start column"},
            end_line: %{type: "integer", description: "0-indexed end line"},
            end_character: %{type: "integer", description: "0-indexed end column"},
            only: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional CodeActionKind filter (e.g. ['quickfix', 'refactor'])"
            }
          },
          required: [
            "sector_id",
            "file_path",
            "start_line",
            "start_character",
            "end_line",
            "end_character"
          ]
        }
      },
      %{
        name: "lsp_apply_code_action",
        description:
          "Apply the WorkspaceEdit attached to a CodeAction returned by lsp_code_action. Writes files on disk; caller is responsible for committing. Returns the list of paths changed.",
        inputSchema: %{
          type: "object",
          properties: %{
            edit: %{
              type: "object",
              description: "The `edit` field of a CodeAction (a WorkspaceEdit with `changes`)"
            }
          },
          required: ["edit"]
        }
      },
      %{
        name: "capture_screenshot",
        description:
          "Take a screenshot of a URL using headless Chromium (Playwright). Returns the absolute path of the saved PNG. Requires :visual_capture_enabled and `npx playwright` on PATH.",
        inputSchema: %{
          type: "object",
          properties: %{
            url: %{type: "string", description: "Page URL to capture"},
            output_path: %{
              type: "string",
              description: "Absolute path where the PNG will be written"
            },
            full_page: %{type: "boolean", description: "Capture full page (default true)"},
            wait_ms: %{
              type: "integer",
              description: "Delay after navigation before capturing (default 0)"
            }
          },
          required: ["url", "output_path"]
        }
      },
      %{
        name: "set_autonomy_tier",
        description:
          "[WRITE] Operator override of a sector's autonomy tier. Takes precedence over the derived tier until cleared (tier=normal).",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: "string", description: "Sector ID"},
            tier: %{
              type: "string",
              enum: ["trusted", "normal", "require_approval"],
              description: "Override tier"
            },
            confirm: %{type: "boolean", description: "Must be true to execute"}
          },
          required: ["sector_id", "tier", "confirm"]
        }
      },
      %{
        name: "knowledge_get",
        description:
          "Read a wiki page by its slug. Returns title, body, tags, and link list. Use sector_id=null for global pages.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{
              type: ["string", "null"],
              description: "Sector ID, or null for global pages"
            },
            slug: %{type: "string", description: "Page slug (kebab-case)"}
          },
          required: ["slug"]
        }
      },
      %{
        name: "knowledge_search",
        description:
          "Semantic search over wiki pages. Returns top-K page summaries ranked by cosine similarity to the query.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{
              type: ["string", "null"],
              description: "Sector ID, or null for global only"
            },
            query: %{type: "string", description: "Free-text query"},
            top_k: %{type: "integer", description: "Number of results (default 5)"},
            min_similarity: %{
              type: "number",
              description: "Score floor; results below this are dropped (default 0.4)"
            }
          },
          required: ["query"]
        }
      },
      %{
        name: "knowledge_links",
        description:
          "Returns pages linked to or from a given page. direction: 'out' | 'in' | 'both' (default both).",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: ["string", "null"], description: "Sector ID"},
            slug: %{type: "string", description: "Page slug"},
            direction: %{
              type: "string",
              enum: ["out", "in", "both"],
              description: "Link direction (default 'both')"
            }
          },
          required: ["slug"]
        }
      },
      %{
        name: "knowledge_index",
        description:
          "Read a curated index (table-of-contents) by name. Returns its structured entries.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: ["string", "null"], description: "Sector ID"},
            name: %{type: "string", description: "Index name"}
          },
          required: ["name"]
        }
      },
      %{
        name: "knowledge_ingest_url",
        description:
          "Fetch a web page, convert to markdown, and persist as a Knowledge.Page in the target sector. Returns a summary {ingested, skipped, errors}. Use sparingly — each call hits the network and embeds.",
        inputSchema: %{
          type: "object",
          properties: %{
            sector_id: %{type: ["string", "null"], description: "Sector ID (or null for global)"},
            url: %{type: "string", description: "Source URL (http or https)"},
            depth: %{
              type: "integer",
              description:
                "Crawl depth: 0 (single page, default) or 1 (follow same-host links one hop)"
            },
            slug: %{type: "string", description: "Override slug (default derived from URL)"},
            title: %{type: "string", description: "Override title (default from <title> or <h1>)"},
            dry_run: %{type: "boolean", description: "Parse but don't persist"}
          },
          required: ["url"]
        }
      }
    ]
  end
end
