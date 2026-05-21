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
            mode: %{type: "string", description: "Filter by mode: 'fast' or 'full'. Omit for all."}
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
            phase: %{type: "string", description: "Phase name: research, requirements, design, planning, validation, sync, scoring"}
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
        name: "start_mission",
        description:
          "[WRITE] Start a mission (or restart a stalled one). Kicks off the phase pipeline from research. Requires confirm: true.",
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Mission ID"},
            fast: %{
              type: "boolean",
              description: "Use fast path (skip full pipeline, single implementation op)",
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
        name: "list_skills",
        description:
          "List skills in the self-improving skill library. Filter by scope (global/sector) or sector_id.",
        inputSchema: %{
          type: "object",
          properties: %{
            scope: %{type: "string", enum: ["global", "sector"], description: "Filter by scope"},
            sector_id: %{type: "string", description: "Filter by sector (only meaningful with scope=sector)"},
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
            status: %{type: "string", enum: ["active", "archived"], description: "New status (optional)"},
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
            sector_id: %{type: "string", description: "Scope stats to a specific sector (optional)"}
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
            sector_id: %{type: "string", description: "Scope stats to a specific sector (optional)"}
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
          required: ["sector_id", "file_path", "start_line", "start_character", "end_line", "end_character"]
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
            sector_id: %{type: ["string", "null"], description: "Sector ID, or null for global pages"},
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
            sector_id: %{type: ["string", "null"], description: "Sector ID, or null for global only"},
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
              description: "Crawl depth: 0 (single page, default) or 1 (follow same-host links one hop)"
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
