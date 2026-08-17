defmodule GiTF.Studio.Tools do
  @moduledoc """
  The planning studio's tool surface — what the planner LLM can do to the
  board. Every tool except `set_phase` and `generate_mockups` creates a
  pending proposal card the user confirms in the UI (see
  `GiTF.Studio.Session`), so this list is also the vocabulary of the live
  board: decisions, constraints, open questions, parti, module graph,
  roadmap items.

  Voice sessions (M4) get the SAME tools — this module is the contract that
  makes text and voice drive one UI.
  """

  @proposal_tools ~w(set_vision set_parti add_decision add_constraint
                     add_open_question resolve_question upsert_module
                     upsert_edge upsert_roadmap_item set_phase
                     propose_schemes propose_storyboard)

  @doc "Tool names that create pending proposal cards."
  def proposal_tools, do: @proposal_tools

  def system_prompt do
    sectors =
      case GiTF.Sector.list() do
        [] -> "none registered yet"
        # Archive records are plain maps with no enforced shape — a sector
        # written without :name must not crash session startup.
        list -> Enum.map_join(list, ", ", &(Map.get(&1, :name) || Map.get(&1, :id, "unnamed")))
      end

    """
    You are the planner in a live "planning studio". A user is discussing a
    software project with you; a board next to the conversation shows the
    plan forming in real time. You update the board EXCLUSIVELY through
    tools — every tool call becomes a card the user confirms or dismisses.

    The factory ("Aramaki") that executes the result runs MISSIONS:
    self-contained units of work an autonomous AI agent completes in a git
    repository without asking questions.

    ## Session phases (gated — set_phase creates a sign-off card the user
    ## must confirm; cost of change rises each phase, so gates are real)
    1. **brief** — interview: vision, users, success, constraints. Capture
       with set_vision / add_decision / add_constraint / add_open_question.
       Early on, propose a parti (set_parti): ONE sentence naming the
       organizing idea of the product. Flag later requests that conflict
       with it.
    2. **concept** — structure: extract modules (upsert_module) and typed
       edges (upsert_edge) as the shape emerges. Offer generate_mockups at
       meaningful forks (2-3 deliberately different style briefs).
    3. **roadmap** — decompose into missions (upsert_roadmap_item): a
       dependency DAG, first item always the walking skeleton (scaffold +
       test harness + one verifiable end-to-end slice). Every goal must be a
       complete standalone mission brief with acceptance criteria and a
       verification command. Prefer vertical slices; use depends_on
       sparingly (diamonds beat chains).
    4. **review** — walk the user through the whole board; they approve in
       the UI (you have no approve tool).

    ## Rituals
    - **Three schemes**: at any strategic fork (architecture, pricing, core
      UX model), call propose_schemes with EXACTLY 2-4 deliberately rough
      alternatives that differ on one named axis. Each states its thesis AND
      its sacrifice. The user picks one (or none) in the UI.
    - **Storyboard**: for the key user journey, call propose_storyboard with
      5-8 panels (caption + one-sentence beat). In voice sessions, narrate
      the panels aloud after the user confirms the card.

    ## Conversational rules
    - ONE question at a time; keep replies short — the board carries the
      detail, your voice carries the conversation.
    - Propose, don't transcribe: turn what you hear into concrete cards
      immediately rather than summarizing at the end.
    - Dismissed cards are feedback — do not re-propose without new
      information (outcomes arrive in [Card outcomes: ...] prefixes).
    - Challenge scope; suggest what to cut for v1.
    - Existing sectors (repositories) the factory knows: #{sectors}. Ask
      early whether this project targets one of them or a new repository —
      record the answer with add_decision.
    """
  end

  def all do
    [
      text_tool("set_vision", "Set or replace the 1-3 sentence product vision."),
      text_tool(
        "set_parti",
        "Set the parti: the single organizing idea of the product, one sentence."
      ),
      text_tool("add_decision", "Record a decision made in the conversation (stack, scope, tradeoff)."),
      text_tool("add_constraint", "Record a hard constraint (budget, tech, compliance, deadline)."),
      text_tool("add_open_question", "Record a question deliberately left open."),
      text_tool(
        "resolve_question",
        "Resolve an open question — pass the question text exactly as recorded."
      ),
      ReqLLM.Tool.new!(
        name: "upsert_module",
        description:
          "Add or update a module bubble on the concept graph (a product capability or subsystem).",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Stable kebab-case id"},
            "label" => %{"type" => "string"},
            "effort" => %{"type" => "string", "enum" => ["s", "m", "l"]},
            "note" => %{"type" => "string", "description" => "One-line description"}
          },
          "required" => ["id", "label"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "upsert_edge",
        description: "Add a typed relationship between two modules on the concept graph.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "from" => %{"type" => "string", "description" => "Module id"},
            "to" => %{"type" => "string", "description" => "Module id"},
            "kind" => %{
              "type" => "string",
              "enum" => ["depends_on", "shares_data", "isolated_from"]
            }
          },
          "required" => ["from", "to"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "upsert_roadmap_item",
        description:
          "Add or update a roadmap item (one future mission). The goal must be a complete standalone brief for an autonomous agent: what to build, acceptance criteria, verification command.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Stable kebab-case id"},
            "title" => %{"type" => "string"},
            "goal" => %{"type" => "string"},
            "depends_on" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["id", "title", "goal"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "generate_mockups",
        description:
          "Generate 2-3 quick throwaway HTML mockup variants of a screen for direction-setting. Each style brief should name a deliberately DIFFERENT direction.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "target" => %{"type" => "string", "description" => "What screen/flow to mock up"},
            "style_briefs" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "2-3 divergent style directions"
            }
          },
          "required" => ["target", "style_briefs"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "set_phase",
        description:
          "Propose advancing the session phase (brief → concept → roadmap → review). This is a GATE: the user signs off by confirming the card.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "phase" => %{"type" => "string", "enum" => ["brief", "concept", "roadmap", "review"]}
          },
          "required" => ["phase"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "propose_schemes",
        description:
          "Present 2-4 deliberately rough alternative schemes at a strategic fork. Differ on ONE named axis; each states its thesis and its sacrifice. The user chooses one in the UI.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "axis" => %{"type" => "string", "description" => "What the schemes differ on"},
            "schemes" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "thesis" => %{"type" => "string", "description" => "2-line strategy statement"},
                  "sacrifice" => %{"type" => "string", "description" => "What this scheme gives up"}
                },
                "required" => ["name", "thesis", "sacrifice"]
              }
            }
          },
          "required" => ["axis", "schemes"]
        },
        callback: fn _ -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "propose_storyboard",
        description:
          "Storyboard a key user journey as 5-8 panels. Tests the product in TIME — pacing, step count — before anything is built.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string", "description" => "Journey name"},
            "panels" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "caption" => %{"type" => "string", "description" => "What happens in this beat"},
                  "description" => %{"type" => "string", "description" => "What the user sees/feels"}
                },
                "required" => ["caption"]
              }
            }
          },
          "required" => ["title", "panels"]
        },
        callback: fn _ -> {:ok, "handled"} end
      )
    ]
  end

  defp text_tool(name, description) do
    ReqLLM.Tool.new!(
      name: name,
      description: description,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      callback: fn _ -> {:ok, "handled"} end
    )
  end
end
