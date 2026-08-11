defmodule GiTF.CLI.ProjectChat do
  @moduledoc """
  Interactive project-planning chat — the discussion phase before Aramaki
  drives a multi-mission project.

  A profile over `GiTF.CLI.Chat`'s engine: the planner interviews the user
  about what to build (vision, users, scope, stack, greenfield vs. existing
  sector), then submits a brief plus a dependency-DAG roadmap of missions via
  the `submit_roadmap` tool. Each roadmap item's goal must stand alone as a
  mission brief for an autonomous agent — the user reviews the roadmap before
  anything is created.

  Returns `{:ok, submission}` where submission has string keys:
  `"name"`, `"brief"`, `"sector"` (`%{"mode" => "new" | "existing", "name" => _}`),
  `"roadmap"` (items with `"id"`, `"title"`, `"goal"`, `"depends_on"`).
  """

  alias GiTF.CLI.{Chat, Format}

  @doc "Start the project planning discussion. `opts` are passed to the chat engine."
  def start(opts \\ []) do
    Chat.start_with_profile(profile(), opts)
  end

  defp profile do
    %{
      label_prefix: "Project planning",
      label: "let's figure out what to build",
      system_prompt: system_prompt(),
      initial_message:
        "I want to plan a new project. Interview me about what to build, then propose a mission roadmap.",
      tools: Chat.core_tools() ++ [submit_roadmap_tool()],
      submit_tool: "submit_roadmap",
      done_message:
        "I'm satisfied with the discussion. Please submit the project roadmap now using the submit_roadmap tool.",
      on_submit: &handle_submit/2
    }
  end

  defp system_prompt do
    sectors =
      case GiTF.Sector.list() do
        [] -> "none registered yet"
        list -> Enum.map_join(list, ", ", &"#{&1.name} (#{&1.id})")
      end

    """
    You are a senior product planner for an autonomous software factory. The
    factory ("Aramaki") executes MISSIONS — self-contained units of work an AI
    agent carries out end-to-end in a git repository (a "sector") without
    asking questions. Your job is to turn a conversation with the user into:

    1. A **brief** — vision, key decisions made during this conversation,
       constraints, and any questions deliberately left open.
    2. A **roadmap** — 3-10 missions forming a dependency DAG. Items only
       depend on items that must genuinely land first; independent items run
       in parallel.

    Interview style:
    - Start broad (what is it, who is it for, what does success look like),
      then narrow (stack, data, integrations, scope cuts for v1).
    - Ask ONE question at a time. Use the ask_choice tool whenever the answer
      is a choice between alternatives (stack, hosting, scope options); mark
      a recommended option. Use plain questions for open-ended answers.
    - Challenge scope: propose what to cut for a first version.
    - 4-8 questions is usually enough. Do not interrogate forever.

    Roadmap quality bar (this is the important part):
    - The FIRST item is always a walking skeleton: repo scaffold, framework,
      test harness, one trivially verifiable end-to-end slice.
    - Every item's `goal` must be a complete mission brief: what to build,
      where it fits, concrete acceptance criteria, and how the agent should
      verify it (tests). Write goals for an agent with NO access to this
      conversation beyond what you write.
    - Prefer vertical slices (feature end-to-end) over horizontal layers.
    - Use `depends_on` sparingly — a diamond (scaffold → two parallel
      features → integration) beats a chain.

    Sector: ask early whether this goes into an existing sector or a new
    (greenfield) repository. Existing sectors: #{sectors}.

    When the picture is clear, call submit_roadmap. If the user rejects it,
    revise based on their feedback and resubmit.
    """
  end

  defp submit_roadmap_tool do
    ReqLLM.Tool.new!(
      name: "submit_roadmap",
      description:
        "Submit the project brief and mission roadmap for user review. Call once the interview has settled vision, scope, stack, and sector.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Short project name (kebab-case)"},
          "brief" => %{
            "type" => "object",
            "properties" => %{
              "vision" => %{"type" => "string", "description" => "1-3 sentence product vision"},
              "decisions" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Key decisions made in this conversation (stack, scope, tradeoffs)"
              },
              "constraints" => %{"type" => "array", "items" => %{"type" => "string"}},
              "open_questions" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Deliberately unresolved questions"
              }
            },
            "required" => ["vision"]
          },
          "sector" => %{
            "type" => "object",
            "properties" => %{
              "mode" => %{"type" => "string", "enum" => ["existing", "new"]},
              "name" => %{
                "type" => "string",
                "description" => "Existing sector name/id, or the name for the new repository"
              }
            },
            "required" => ["mode", "name"]
          },
          "roadmap" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "string", "description" => "Stable kebab-case item id"},
                "title" => %{"type" => "string"},
                "goal" => %{
                  "type" => "string",
                  "description" =>
                    "Complete, self-contained mission brief with acceptance criteria and verification"
                },
                "depends_on" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" => "Ids of prerequisite items"
                }
              },
              "required" => ["id", "title", "goal"]
            }
          }
        },
        "required" => ["name", "brief", "sector", "roadmap"]
      },
      callback: fn _args -> {:ok, "handled"} end
    )
  end

  # -- Review & accept ---------------------------------------------------------

  defp handle_submit(state, args) do
    submission = normalize(args)
    render(submission)

    answer = IO.gets("  Accept this roadmap? [y/n] ") |> String.trim() |> String.downcase()

    if answer in ["y", "yes", ""] do
      Format.success("Roadmap accepted with #{length(submission["roadmap"])} mission(s).")
      {%{state | plan: submission, done: true}, true}
    else
      IO.puts("  Sending feedback to revise the roadmap...")
      {state, false}
    end
  end

  defp render(submission) do
    ansi = fn code, text -> code <> text <> IO.ANSI.reset() end
    dim = fn text -> ansi.(IO.ANSI.faint(), text) end

    brief = submission["brief"]
    sector = submission["sector"]

    IO.puts("")
    IO.puts(ansi.(IO.ANSI.green() <> IO.ANSI.bright(), "Project: #{submission["name"]}"))
    IO.puts(dim.(brief["vision"] || ""))

    sector_line =
      case sector["mode"] do
        "new" -> "new repository \"#{sector["name"]}\" (created at approval)"
        _ -> "existing sector \"#{sector["name"]}\""
      end

    IO.puts(dim.("Sector: #{sector_line}"))

    for {label, key} <- [{"Decisions", "decisions"}, {"Constraints", "constraints"}, {"Open questions", "open_questions"}],
        items = brief[key] || [],
        items != [] do
      IO.puts("")
      IO.puts("  " <> ansi.(IO.ANSI.cyan(), label <> ":"))
      Enum.each(items, &IO.puts("   - #{&1}"))
    end

    IO.puts("")
    IO.puts("  " <> ansi.(IO.ANSI.cyan(), "Roadmap:"))

    Enum.each(submission["roadmap"], fn item ->
      deps =
        case item["depends_on"] do
          [] -> ""
          deps -> dim.("  (after: #{Enum.join(deps, ", ")})")
        end

      IO.puts("   " <> ansi.(IO.ANSI.yellow(), "[#{item["id"]}]") <> " #{item["title"]}#{deps}")

      (item["goal"] || "")
      |> String.split("\n", trim: true)
      |> Enum.take(2)
      |> Enum.each(&IO.puts("       " <> dim.(String.slice(&1, 0, 100))))
    end)

    IO.puts("")
  end

  defp normalize(args) do
    args
    |> stringify()
    |> Map.update("brief", %{}, &stringify/1)
    |> Map.update("sector", %{"mode" => "new", "name" => "project"}, &stringify/1)
    |> Map.update("roadmap", [], fn items ->
      Enum.map(items, fn item ->
        item
        |> stringify()
        |> Map.put_new("depends_on", [])
      end)
    end)
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
