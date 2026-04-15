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
      }
    ]
  end
end
