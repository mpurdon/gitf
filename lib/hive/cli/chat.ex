defmodule Hive.CLI.Chat do
  @moduledoc """
  Interactive API-driven chat for quest planning.

  Runs a multi-turn conversation with the Gemini API to gather requirements
  and produce a structured implementation plan. Supports image attachments,
  multiple-choice questions via tool calls, and clipboard paste on macOS.
  """

  alias Hive.CLI.Format
  alias Hive.CLI.Select

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)

  defstruct [
    :quest,
    :api_key,
    :model,
    :system_prompt,
    messages: [],
    pending_images: [],
    plan: nil,
    done: false
  ]

  # -- Public API -------------------------------------------------------------

  @doc """
  Start an interactive planning chat for a quest.
  Returns `{:ok, plan}` on success or `{:error, reason}` if cancelled/failed.
  """
  def start(quest, opts \\ []) do
    model = opts[:model] || Hive.Runtime.ModelResolver.resolve("sonnet")
    api_key = resolve_api_key()

    unless api_key do
      Format.error("No API key. Set GOOGLE_API_KEY or [llm] keys.google_api_key in .hive/config.toml.")
      {:error, :no_api_key}
    else
      codebase = build_codebase_context(quest)
      system_prompt = build_system_prompt(quest, codebase)

      state = %__MODULE__{
        quest: quest,
        api_key: api_key,
        model: map_model(model),
        system_prompt: system_prompt
      }

      IO.puts("")
      IO.puts(color(:cyan) <> "Planning: " <> reset() <> quest.goal)
      IO.puts(dim("Commands: /image <path>  /paste  /done  /quit  /help"))
      IO.puts("")

      state =
        state
        |> append_user([%{"text" => "I want to: #{quest.goal}\n\nPlease help me plan this. Start by asking me clarifying questions about what I need."}])
        |> call_and_handle()

      case chat_loop(state) do
        %{plan: plan} when plan != nil -> {:ok, plan}
        _ -> {:error, :cancelled}
      end
    end
  end

  # -- Chat loop --------------------------------------------------------------

  defp chat_loop(%{done: true} = state), do: state

  defp chat_loop(state) do
    case read_input() do
      :eof ->
        state

      input when input in ~w(/quit /exit /q) ->
        Format.warn("Planning cancelled.")
        state

      input when input in ~w(/help /h /?) ->
        print_help()
        chat_loop(state)

      "/done" ->
        state
        |> append_user([%{"text" => "I'm satisfied. Please submit the implementation plan now using the submit_plan tool."}])
        |> call_and_handle()
        |> chat_loop()

      "/image " <> path ->
        handle_attach(state, String.trim(path))

      "/attach " <> path ->
        handle_attach(state, String.trim(path))

      "/paste" ->
        handle_clipboard(state)

      "" ->
        chat_loop(state)

      input ->
        trimmed = String.trim(input)
        expanded = Path.expand(trimmed)

        if image_file?(expanded) do
          state = %{state | pending_images: state.pending_images ++ [expanded]}
          IO.puts(color(:green) <> "  Attached: " <> reset() <> Path.basename(expanded))
          IO.puts(dim("  Type a message to send with this image, or attach more."))
          chat_loop(state)
        else
          parts = build_user_parts(trimmed, state.pending_images)

          %{state | pending_images: []}
          |> append_user(parts)
          |> call_and_handle()
          |> chat_loop()
        end
    end
  end

  # -- Image handling ---------------------------------------------------------

  defp handle_attach(state, raw_path) do
    path = Path.expand(raw_path)

    state =
      if File.exists?(path) and image_file?(path) do
        IO.puts(color(:green) <> "  Attached: " <> reset() <> Path.basename(path))
        IO.puts(dim("  Type a message to send with this image, or attach more."))
        %{state | pending_images: state.pending_images ++ [path]}
      else
        IO.puts(color(:red) <> "  Not a valid image: " <> reset() <> raw_path)
        state
      end

    chat_loop(state)
  end

  defp handle_clipboard(state) do
    case grab_clipboard_image() do
      {:ok, path} ->
        state = %{state | pending_images: state.pending_images ++ [path]}
        IO.puts(color(:green) <> "  Clipboard image attached." <> reset())
        IO.puts(dim("  Type a message to send with this image."))
        chat_loop(state)

      {:error, reason} ->
        IO.puts(color(:red) <> "  " <> reason <> reset())
        chat_loop(state)
    end
  end

  defp grab_clipboard_image do
    script = ~S"""
    try
      set imageData to the clipboard as «class PNGf»
      set filePath to (POSIX path of (path to temporary items folder)) & "hive_clipboard.png"
      set fileRef to open for access filePath with write permission
      set eof fileRef to 0
      write imageData to fileRef
      close access fileRef
      return filePath
    on error
      return "NO_IMAGE"
    end try
    """

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {path, 0} ->
        path = String.trim(path)
        if path == "NO_IMAGE", do: {:error, "No image on clipboard."}, else: {:ok, path}

      _ ->
        {:error, "Could not access clipboard."}
    end
  end

  defp build_user_parts(text, []) do
    [%{"text" => text}]
  end

  defp build_user_parts(text, images) do
    image_parts =
      Enum.flat_map(images, fn path ->
        case File.read(path) do
          {:ok, data} ->
            [%{"inline_data" => %{"mime_type" => mime_type(path), "data" => Base.encode64(data)}}]

          {:error, _} ->
            []
        end
      end)

    [%{"text" => text} | image_parts]
  end

  # -- API communication ------------------------------------------------------

  defp call_and_handle(state) do
    IO.write(dim("  Thinking..."))

    case call_gemini(state) do
      {:ok, response} ->
        clear_line()
        handle_response(state, response)

      {:error, reason} ->
        clear_line()
        Format.error("API error: #{inspect(reason)}")
        state
    end
  end

  defp call_gemini(state) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/#{state.model}:generateContent?key=#{state.api_key}"

    body = %{
      "system_instruction" => %{"parts" => [%{"text" => state.system_prompt}]},
      "contents" => state.messages,
      "tools" => [%{"function_declarations" => tool_declarations()}],
      "generationConfig" => %{"temperature" => 0.7, "maxOutputTokens" => 8192}
    }

    case Req.post(url, json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_response(state, response) do
    candidate = List.first(response["candidates"] || [])
    parts = get_in(candidate, ["content", "parts"]) || []

    # Add full model response to history
    state = append_model(state, parts)

    # Display any text
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map_join("\n", & &1["text"])

    unless text == "" do
      IO.puts("")
      IO.puts(text)
      IO.puts("")
    end

    # Handle tool calls
    tool_calls = Enum.filter(parts, &Map.has_key?(&1, "functionCall"))

    if tool_calls != [] do
      handle_tool_calls(state, tool_calls)
    else
      state
    end
  end

  # -- Tool handling ----------------------------------------------------------

  defp handle_tool_calls(state, tool_calls) do
    {state, responses} =
      Enum.reduce(tool_calls, {state, []}, fn call, {s, resps} ->
        name = call["functionCall"]["name"]
        args = call["functionCall"]["args"] || %{}

        case name do
          "ask_choice" ->
            answer = do_ask_choice(args)
            resp = fn_response("ask_choice", %{"result" => answer})
            {s, resps ++ [resp]}

          "submit_plan" ->
            {s, accepted?} = do_submit_plan(s, args)

            if accepted? do
              resp = fn_response("submit_plan", %{"result" => "Plan accepted."})
              {s, resps ++ [resp]}
            else
              feedback = IO.gets("  What would you like to change? ") |> String.trim()
              resp = fn_response("submit_plan", %{"result" => "Plan rejected. User feedback: #{feedback}"})
              {s, resps ++ [resp]}
            end

          _ ->
            {s, resps}
        end
      end)

    if state.done do
      state
    else
      state
      |> append_user(responses)
      |> call_and_handle()
    end
  end

  defp do_ask_choice(%{"question" => question, "options" => options, "multi" => true})
       when is_list(options) do
    case Select.multi_select(question, normalize_options(options)) do
      nil -> "No preference, please decide for me."
      labels -> Enum.join(labels, ", ")
    end
  end

  defp do_ask_choice(%{"question" => question, "options" => options}) when is_list(options) do
    case Select.select(question, normalize_options(options)) do
      nil -> "No preference, please decide for me."
      label -> label
    end
  end

  defp do_ask_choice(_bad_args) do
    "No preference, please decide for me."
  end

  # Pass structured options through (maps with label/description/recommended)
  # or wrap plain strings for backward compat
  defp normalize_options(options) do
    Enum.map(options, fn
      opt when is_binary(opt) -> opt
      %{"label" => _} = opt -> opt
      other -> inspect(other)
    end)
  end

  defp do_submit_plan(state, args) do
    name = args["name"] || state.quest.goal
    summary = args["summary"] || ""
    jobs = args["jobs"] || []

    IO.puts("")
    IO.puts(color(:green) <> color(:bright) <> "Plan: #{name}" <> reset())
    IO.puts(dim(summary))
    IO.puts("")

    jobs
    |> Enum.with_index(1)
    |> Enum.each(fn {job, idx} ->
      type = job["job_type"] || "implementation"
      type_color = case type do
        "research" -> :cyan
        "verification" -> :magenta
        _ -> :yellow
      end
      badge = color(type_color) <> "[#{type}]" <> reset()
      IO.puts("  #{idx}. #{badge} #{job["title"]}")

      if desc = job["description"] do
        IO.puts("     " <> dim(desc))
      end

      case job["depends_on"] do
        deps when is_list(deps) and deps != [] ->
          dep_nums = Enum.map(deps, &(&1 + 1)) |> Enum.join(", ")
          IO.puts("     " <> dim("depends on: #{dep_nums}"))

        _ ->
          :ok
      end
    end)

    IO.puts("")
    answer = IO.gets("  Accept this plan? [y/n] ") |> String.trim() |> String.downcase()

    if answer in ["y", "yes", ""] do
      plan = %{name: name, summary: summary, jobs: jobs}
      Format.success("Plan accepted with #{length(jobs)} job(s).")
      {%{state | plan: plan, done: true}, true}
    else
      IO.puts(dim("  Sending feedback to revise the plan..."))
      {state, false}
    end
  end

  # -- Input helpers ----------------------------------------------------------

  defp read_input do
    case IO.gets(color(:green) <> "> " <> reset()) do
      :eof -> :eof
      {:error, _} -> :eof
      data -> String.trim(data)
    end
  end

  # -- Message history --------------------------------------------------------

  defp append_user(state, parts) do
    %{state | messages: state.messages ++ [%{"role" => "user", "parts" => parts}]}
  end

  defp append_model(state, parts) do
    %{state | messages: state.messages ++ [%{"role" => "model", "parts" => parts}]}
  end

  defp fn_response(name, content) do
    %{"functionResponse" => %{"name" => name, "response" => content}}
  end

  # -- Codebase context -------------------------------------------------------

  defp build_codebase_context(quest) do
    comb_id = Map.get(quest, :comb_id)

    case comb_id && Hive.Store.get(:combs, comb_id) do
      nil ->
        "No codebase context available."

      comb ->
        path = comb.path

        if File.dir?(path) do
          files = list_files(path, 3) |> Enum.sort() |> Enum.take(150)

          """
          Comb: #{Map.get(comb, :name, "unknown")} (#{path})

          File tree:
          #{Enum.join(files, "\n")}
          """
        else
          "Comb: #{Map.get(comb, :name, "unknown")} (#{path}, not accessible)"
        end
    end
  rescue
    _ -> "Could not read codebase context."
  end

  defp list_files(root, max_depth) do
    do_list_files(root, root, max_depth)
  end

  @skip_dirs ~w(node_modules _build deps vendor .git .hive __pycache__ .next .cache)

  defp do_list_files(_root, _path, 0), do: []

  defp do_list_files(root, path, depth) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reject(&(&1 in @skip_dirs))
        |> Enum.flat_map(fn entry ->
          full = Path.join(path, entry)
          relative = Path.relative_to(full, root)

          if File.dir?(full) do
            [relative <> "/" | do_list_files(root, full, depth - 1)]
          else
            [relative]
          end
        end)

      _ ->
        []
    end
  end

  # -- System prompt ----------------------------------------------------------

  defp build_system_prompt(quest, codebase) do
    """
    You are an expert software architect helping plan an implementation.

    ## Your Role
    Gather requirements and create an implementation plan for: "#{quest.goal}"

    ## Codebase Context
    #{codebase}

    ## Instructions
    1. Start by understanding the user's goal. Ask 2-3 focused clarifying questions.
    2. Use the `ask_choice` tool for questions with clear discrete options (frameworks, scope, approach).
    3. Use regular text for open-ended questions.
    4. The user may attach images (screenshots, diagrams, mockups) — analyze them carefully.
    5. After gathering enough context (aim for 3-5 exchanges), call `submit_plan` with the structured plan.

    ## Tool Usage
    - `ask_choice`: Present options the user selects with arrow keys. Each option should have a `label`, a `description` (brief explanation), and optionally `recommended: true` for your top pick. Good for: tech choices, scope decisions, feature priorities. Use `multi: true` when the user should pick multiple items.
    - `submit_plan`: Submit the final plan with jobs. Each job should be a focused unit of work (1-3 hours) that an AI coding agent can execute independently.

    ## Plan Guidelines
    - Break work into small, focused jobs
    - Use job_type "research" for unknowns and exploration
    - Use job_type "implementation" for coding work
    - Use job_type "verification" for testing and validation
    - Set depends_on (0-based indices) to define execution order
    - Each job's description should have enough detail for an AI agent to execute it without further context

    Be conversational but efficient. Don't over-ask — 3-5 exchanges max before submitting a plan.
    """
  end

  # -- Tool declarations ------------------------------------------------------

  defp tool_declarations do
    [
      %{
        "name" => "ask_choice",
        "description" =>
          "Present a selection prompt. The user navigates with arrow keys and presses enter. " <>
            "For multi=true, the user can toggle multiple items with space before confirming.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "question" => %{"type" => "string", "description" => "The question to ask"},
            "options" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "label" => %{"type" => "string", "description" => "The option text"},
                  "description" => %{
                    "type" => "string",
                    "description" => "Brief explanation shown when this option is focused"
                  },
                  "recommended" => %{
                    "type" => "boolean",
                    "description" => "Mark as true for the recommended choice"
                  }
                },
                "required" => ["label"]
              },
              "description" => "2-6 options to choose from"
            },
            "multi" => %{
              "type" => "boolean",
              "description" =>
                "If true, user can select multiple options. Default false (single select)."
            }
          },
          "required" => ["question", "options"]
        }
      },
      %{
        "name" => "submit_plan",
        "description" =>
          "Submit the final implementation plan. Call after gathering enough information.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Short quest name"},
            "summary" => %{"type" => "string", "description" => "1-2 sentence summary"},
            "jobs" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "title" => %{"type" => "string"},
                  "description" => %{
                    "type" => "string",
                    "description" => "Detailed description for an AI agent to execute"
                  },
                  "job_type" => %{
                    "type" => "string",
                    "enum" => ["research", "implementation", "verification"]
                  },
                  "depends_on" => %{
                    "type" => "array",
                    "items" => %{"type" => "integer"},
                    "description" => "0-based indices of prerequisite jobs"
                  }
                },
                "required" => ["title", "description", "job_type"]
              }
            }
          },
          "required" => ["name", "summary", "jobs"]
        }
      }
    ]
  end

  # -- Terminal helpers -------------------------------------------------------

  defp image_file?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_exts and File.exists?(path)
  end

  defp mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      _ -> "application/octet-stream"
    end
  end

  defp map_model(model) do
    clean = String.replace(model, "google:", "")
    if String.starts_with?(clean, "models/"), do: clean, else: "models/#{clean}"
  end

  defp resolve_api_key do
    System.get_env("GOOGLE_API_KEY") ||
      System.get_env("GEMINI_API_KEY") ||
      Application.get_env(:req_llm, :google_api_key) ||
      config_api_key()
  end

  defp config_api_key do
    with {:ok, root} <- Hive.hive_dir(),
         {:ok, config} <- Hive.Config.read_config(Path.join([root, ".hive", "config.toml"])),
         val when is_binary(val) and val != "" <- get_in(config, ["llm", "keys", "google_api_key"]) do
      val
    else
      _ -> nil
    end
  end

  defp color(:cyan), do: IO.ANSI.cyan()
  defp color(:green), do: IO.ANSI.green()
  defp color(:red), do: IO.ANSI.red()
  defp color(:yellow), do: IO.ANSI.yellow()
  defp color(:magenta), do: IO.ANSI.magenta()
  defp color(:bright), do: IO.ANSI.bright()
  defp dim(text), do: IO.ANSI.faint() <> text <> IO.ANSI.reset()
  defp reset, do: IO.ANSI.reset()
  defp clear_line, do: IO.write("\r\e[K")

  defp print_help do
    IO.puts("")
    IO.puts(color(:bright) <> "Commands:" <> reset())
    IO.puts("  /image <path>  Attach an image file")
    IO.puts("  /paste         Attach image from clipboard (macOS)")
    IO.puts("  /done          Ask the AI to finalize and submit the plan")
    IO.puts("  /quit          Cancel planning")
    IO.puts("  /help          Show this help")
    IO.puts("")
    IO.puts(dim("Use arrow keys for selections. Drag-and-drop image files into the terminal."))
    IO.puts("")
  end
end
