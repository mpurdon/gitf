defmodule GiTF.CLI.Chat do
  @moduledoc """
  Interactive chat for mission planning.

  Runs a multi-turn conversation via ReqLLM (provider-agnostic) to gather
  requirements and produce a structured implementation plan. Supports image
  attachments, multiple-choice questions via tool calls, and clipboard paste
  on macOS. Works with any provider configured in ModelResolver (Anthropic,
  Google, etc.).
  """

  alias GiTF.CLI.Format
  alias GiTF.CLI.Select
  alias GiTF.Runtime.{LLMClient, ModelResolver}

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)
  @max_retries 3

  # When a provider's quota is exhausted, try these alternatives (in order).
  # Only models whose provider has a configured API key will be attempted.
  @fallback_chain %{
    "google:gemini-2.5-pro" => ["anthropic:claude-sonnet-4-6", "google:gemini-2.5-flash"],
    "google:gemini-2.5-flash" => ["anthropic:claude-sonnet-4-6", "google:gemini-2.0-flash"],
    "google:gemini-2.0-flash" => ["anthropic:claude-haiku-4-5"],
    "anthropic:claude-opus-4-6" => ["google:gemini-2.5-pro", "anthropic:claude-sonnet-4-6"],
    "anthropic:claude-sonnet-4-6" => ["google:gemini-2.5-flash"],
    "anthropic:claude-haiku-4-5" => ["google:gemini-2.0-flash"]
  }

  @provider_env_vars %{
    "google" => "GOOGLE_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "bedrock" => "AWS_ACCESS_KEY_ID"
  }

  defstruct [
    :mission,
    :model,
    :system_prompt,
    context: nil,
    tools: [],
    pending_images: [],
    plan: nil,
    done: false,
    failed_providers: MapSet.new()
  ]

  # -- Public API -------------------------------------------------------------

  @doc """
  Start an interactive planning chat for a mission.
  Returns `{:ok, plan}` on success or `{:error, reason}` if cancelled/failed.
  """
  def start(mission, opts \\ []) do
    # Ensure API keys from .gitf/config.toml are loaded into env vars
    GiTF.Runtime.Keys.load()

    if ModelResolver.ollama_mode?() do
      ModelResolver.setup_ollama_env()
    end

    # Planning chat always uses the API (needs tool calling for ask_choice/submit_plan).
    # In CLI mode, warn and use API anyway; in ollama mode, use local models via API.
    if ModelResolver.execution_mode() == :cli do
      IO.puts(IO.ANSI.yellow() <> "[WARN] Planning chat requires API access (tool calling). " <>
        "Bees will use Claude CLI, but planning uses API." <> IO.ANSI.reset())
    end

    model = opts[:model] || ModelResolver.resolve("opus")
    codebase = build_codebase_context(mission)
    system_prompt = build_system_prompt(mission, codebase)
    tools = build_tools()

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.system(system_prompt),
        ReqLLM.Context.user("I want to: #{mission.goal}\n\nPlease help me plan this. Start by asking me clarifying questions about what I need.")
      ])

    state = %__MODULE__{
      mission: mission,
      model: model,
      system_prompt: system_prompt,
      context: context,
      tools: tools
    }

    provider = ModelResolver.provider(model)

    IO.puts("")
    IO.puts(color(:cyan) <> "Planning: " <> reset() <> mission.goal)
    IO.puts(dim("Provider: #{provider} · Model: #{ModelResolver.model_id(model)}"))
    IO.puts(dim("Commands: /image <path>  /paste  /done  /quit  /help"))
    IO.puts("")

    state = call_and_handle(state)

    case chat_loop(state) do
      %{plan: plan} when plan != nil -> {:ok, plan}
      _ -> {:error, :cancelled}
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
        |> append_user("I'm satisfied. Please submit the implementation plan now using the submit_plan tool.")
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
          state
          |> append_user_with_images(trimmed)
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
      set filePath to (POSIX path of (path to temporary items folder)) & "gitf_clipboard.png"
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

  # -- API communication ------------------------------------------------------

  defp call_and_handle(state, retries \\ 0) do
    provider = ModelResolver.provider(state.model)

    # Circuit breaker: skip providers that already failed this session
    if MapSet.member?(state.failed_providers, provider) do
      case find_fallback_model(state.model, state.failed_providers) do
        {:ok, fallback} ->
          new_provider = ModelResolver.provider(fallback)
          Format.info("Skipping #{provider} (tripped). Using #{new_provider}:#{ModelResolver.model_id(fallback)}")
          call_and_handle(%{state | model: fallback}, 0)

        :none ->
          Format.error("All configured providers have failed. Add more API keys in .gitf/config.toml under [llm.keys]")
          state
      end
    else
      IO.write(dim("  Thinking..."))

      generate_opts = [
        tools: state.tools,
        temperature: 0.7,
        max_tokens: 8192
      ]

      case LLMClient.generate_text(state.model, state.context, generate_opts) do
        {:ok, response} ->
          clear_line()
          handle_response(state, response)

        {:error, reason} ->
          clear_line()
          handle_api_error(state, reason, retries)
      end
    end
  end

  defp handle_api_error(state, error, retries) do
    case classify_error(error) do
      {:rate_limited, delay} when retries < @max_retries ->
        IO.puts(dim("  Rate limited. Retrying in #{delay}s... (attempt #{retries + 1}/#{@max_retries})"))
        Process.sleep(delay * 1000)
        call_and_handle(state, retries + 1)

      {:rate_limited, _delay} ->
        provider = ModelResolver.provider(state.model)
        Format.error("Rate limited by #{provider} after #{@max_retries} retries.")
        trip_and_fallback(state, provider)

      {:quota_exhausted, provider} ->
        Format.warn("#{provider} quota exhausted.")
        trip_and_fallback(state, provider)

      {:auth_error, provider} ->
        Format.error("Authentication failed for #{provider}. Check your API key in .gitf/config.toml")
        trip_and_fallback(state, provider)

      {:api_error, message} ->
        Format.error(message)
        state
    end
  end

  # Trip the circuit breaker for this provider and attempt fallback
  defp trip_and_fallback(state, failed_provider) do
    state = %{state | failed_providers: MapSet.put(state.failed_providers, failed_provider)}

    case find_fallback_model(state.model, state.failed_providers) do
      {:ok, fallback} ->
        new_provider = ModelResolver.provider(fallback)
        new_model_id = ModelResolver.model_id(fallback)
        Format.info("Falling back to #{new_provider}:#{new_model_id}")
        call_and_handle(%{state | model: fallback}, 0)

      :none ->
        Format.error("All configured providers have failed. Add more API keys in .gitf/config.toml under [llm.keys]")
        state
    end
  end

  defp classify_error(%{status: 429} = error) do
    reason = Map.get(error, :reason, "")

    if quota_exhausted?(reason) do
      {:quota_exhausted, extract_provider_from_error(error)}
    else
      delay = extract_retry_delay(error)
      {:rate_limited, delay}
    end
  end

  defp classify_error(%{status: status}) when status in [401, 403] do
    {:auth_error, "unknown"}
  end

  defp classify_error(%{status: status, reason: reason}) when is_integer(status) do
    {:api_error, "API error (#{status}): #{truncate_reason(reason)}"}
  end

  defp classify_error(%{reason: reason}) when is_binary(reason) do
    cond do
      String.contains?(reason, "429") and quota_exhausted?(reason) ->
        {:quota_exhausted, extract_provider_from_reason(reason)}

      String.contains?(reason, "429") ->
        delay = extract_retry_delay_from_reason(reason)
        {:rate_limited, delay}

      String.contains?(reason, "401") or String.contains?(reason, "403") or
          String.contains?(reason, "authentication") or String.contains?(reason, "API key") ->
        {:auth_error, extract_provider_from_reason(reason)}

      true ->
        {:api_error, truncate_reason(reason)}
    end
  end

  defp classify_error(error) do
    {:api_error, "Unexpected error: #{inspect(error) |> String.slice(0, 200)}"}
  end

  defp quota_exhausted?(reason) when is_binary(reason) do
    String.contains?(reason, "quota") or
      String.contains?(reason, "RESOURCE_EXHAUSTED") or
      (String.contains?(reason, "exceeded") and String.contains?(reason, "limit"))
  end

  defp quota_exhausted?(_), do: false

  defp extract_retry_delay(%{response_body: %{"error" => %{"details" => details}}})
       when is_list(details) do
    retry_info =
      Enum.find(details, fn d ->
        Map.get(d, "@type", "") |> String.contains?("RetryInfo")
      end)

    case retry_info do
      %{"retryDelay" => delay_str} -> parse_delay(delay_str)
      _ -> 5
    end
  end

  defp extract_retry_delay(_), do: 5

  defp extract_retry_delay_from_reason(reason) do
    case Regex.run(~r/retry in (\d+(?:\.\d+)?)s/i, reason) do
      [_, seconds] ->
        {delay, _} = Float.parse(seconds)
        ceil(delay)

      _ ->
        5
    end
  end

  defp parse_delay(delay_str) when is_binary(delay_str) do
    # Parse "40s", "40.5s", etc.
    case Float.parse(String.replace(delay_str, "s", "")) do
      {seconds, _} -> ceil(seconds)
      :error -> 5
    end
  end

  defp parse_delay(_), do: 5

  defp extract_provider_from_error(%{reason: reason}) when is_binary(reason) do
    extract_provider_from_reason(reason)
  end

  defp extract_provider_from_error(_), do: "unknown"

  defp extract_provider_from_reason(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "Google") or String.contains?(reason, "generativelanguage") ->
        "google"

      String.contains?(reason, "Anthropic") or String.contains?(reason, "anthropic") ->
        "anthropic"

      String.contains?(reason, "OpenAI") or String.contains?(reason, "openai") ->
        "openai"

      true ->
        "unknown"
    end
  end

  defp extract_provider_from_reason(_), do: "unknown"

  defp find_fallback_model(current_model, %MapSet{} = failed_providers) do
    candidates = Map.get(@fallback_chain, current_model, [])

    fallback =
      Enum.find(candidates, fn model ->
        provider = ModelResolver.provider(model)
        not MapSet.member?(failed_providers, provider) and provider_has_key?(provider)
      end)

    case fallback do
      nil -> :none
      model -> {:ok, model}
    end
  end

  defp provider_has_key?(provider) do
    case Map.get(@provider_env_vars, provider) do
      nil -> false
      env_var -> System.get_env(env_var) not in [nil, ""]
    end
  end

  defp truncate_reason(reason) when is_binary(reason) do
    if String.length(reason) > 200 do
      String.slice(reason, 0, 200) <> "..."
    else
      reason
    end
  end

  defp truncate_reason(other), do: inspect(other) |> truncate_reason()

  defp handle_response(state, response) do
    classified = ReqLLM.Response.classify(response)

    # Update context from response (includes assistant message)
    state = %{state | context: response.context}

    case classified.type do
      :final_answer ->
        text = classified.text || ""

        unless text == "" do
          IO.puts("")
          IO.puts(text)
          IO.puts("")
        end

        state

      :tool_calls ->
        # Display any text that came with the tool calls
        text = classified.text || ""

        unless text == "" do
          IO.puts("")
          IO.puts(text)
          IO.puts("")
        end

        handle_tool_calls(state, classified.tool_calls)
    end
  end

  # -- Tool handling ----------------------------------------------------------

  defp handle_tool_calls(state, tool_calls) do
    {state, tool_results} =
      Enum.reduce(tool_calls, {state, []}, fn tc, {s, results} ->
        case tc.name do
          "ask_choice" ->
            answer = do_ask_choice(tc.arguments)
            {s, results ++ [{tc, answer}]}

          "submit_plan" ->
            {s, accepted?} = do_submit_plan(s, tc.arguments)

            if accepted? do
              {s, results ++ [{tc, "Plan accepted."}]}
            else
              feedback = IO.gets("  What would you like to change? ") |> String.trim()
              {s, results ++ [{tc, "Plan rejected. User feedback: #{feedback}"}]}
            end

          _ ->
            {s, results ++ [{tc, "Unknown tool: #{tc.name}"}]}
        end
      end)

    if state.done do
      state
    else
      # Append tool results to context and continue
      context =
        Enum.reduce(tool_results, state.context, fn {tc, result}, ctx ->
          ReqLLM.Context.append(ctx, ReqLLM.Context.tool_result(tc.id, result))
        end)

      %{state | context: context}
      |> call_and_handle()
    end
  end

  defp do_ask_choice(%{"question" => question, "options" => options, "multi" => true})
       when is_list(options) do
    opts = normalize_options(options)

    case Select.multi_select(question, opts) do
      nil -> text_multi_select(question, opts)
      labels -> Enum.join(labels, ", ")
    end
  end

  # Handle atom keys (some providers return atoms)
  defp do_ask_choice(%{question: question, options: options, multi: true})
       when is_list(options) do
    do_ask_choice(%{"question" => question, "options" => options, "multi" => true})
  end

  defp do_ask_choice(%{"question" => question, "options" => options}) when is_list(options) do
    opts = normalize_options(options)

    case Select.select(question, opts) do
      nil -> text_select(question, opts)
      label -> label
    end
  end

  defp do_ask_choice(%{question: question, options: options}) when is_list(options) do
    do_ask_choice(%{"question" => question, "options" => options})
  end

  defp do_ask_choice(_bad_args) do
    answer = IO.gets("  Your answer: ") |> String.trim()
    if answer == "", do: "No preference, please decide for me.", else: answer
  end

  # Text-based fallback when TUI selector fails
  defp text_select(_question, options) do
    labels = extract_labels(options)
    IO.puts("  " <> dim("(Use number to select)"))

    Enum.with_index(labels, 1)
    |> Enum.each(fn {label, idx} -> IO.puts("  #{idx}. #{label}") end)

    answer = IO.gets("  > ") |> String.trim()

    case Integer.parse(answer) do
      {n, _} when n >= 1 and n <= length(labels) -> Enum.at(labels, n - 1)
      _ -> List.first(labels) || "No preference"
    end
  end

  defp text_multi_select(_question, options) do
    labels = extract_labels(options)
    IO.puts("  " <> dim("(Enter numbers separated by commas, e.g. 1,3,4)"))

    Enum.with_index(labels, 1)
    |> Enum.each(fn {label, idx} -> IO.puts("  #{idx}. #{label}") end)

    answer = IO.gets("  > ") |> String.trim()

    selected =
      answer
      |> String.split(~r/[,\s]+/)
      |> Enum.flat_map(fn s ->
        case Integer.parse(String.trim(s)) do
          {n, _} when n >= 1 and n <= length(labels) -> [Enum.at(labels, n - 1)]
          _ -> []
        end
      end)

    if selected == [], do: Enum.join(labels, ", "), else: Enum.join(selected, ", ")
  end

  defp extract_labels(options) do
    Enum.map(options, fn
      %{"label" => l} -> l
      %{label: l} -> l
      opt when is_binary(opt) -> opt
      other -> inspect(other)
    end)
  end

  defp normalize_options(options) do
    Enum.map(options, fn
      opt when is_binary(opt) -> opt
      %{"label" => _} = opt -> opt
      %{label: l} = opt ->
        %{"label" => l}
        |> then(fn m -> if opt[:description], do: Map.put(m, "description", opt[:description]), else: m end)
        |> then(fn m -> if opt[:recommended], do: Map.put(m, "recommended", true), else: m end)
      other -> inspect(other)
    end)
  end

  defp do_submit_plan(state, args) do
    # Handle both string and atom keys
    name = args["name"] || args[:name] || state.mission.goal
    summary = args["summary"] || args[:summary] || ""
    ops = args["ops"] || args[:ops] || []

    IO.puts("")
    IO.puts(color(:green) <> color(:bright) <> "Plan: #{name}" <> reset())
    IO.puts(dim(summary))
    IO.puts("")

    ops
    |> Enum.with_index(1)
    |> Enum.each(fn {op, idx} ->
      type = op["op_type"] || op[:op_type] || "implementation"
      title = op["title"] || op[:title] || "Untitled"
      desc = op["description"] || op[:description]
      deps = op["depends_on"] || op[:depends_on]

      type_color = case type do
        "research" -> :cyan
        "verification" -> :magenta
        _ -> :yellow
      end
      badge = color(type_color) <> "[#{type}]" <> reset()
      IO.puts("  #{idx}. #{badge} #{title}")

      if desc do
        IO.puts("     " <> dim(desc))
      end

      case deps do
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
      # Normalize op keys to strings for plan_handler
      normalized_jobs = Enum.map(ops, fn op ->
        %{
          "title" => op["title"] || op[:title] || "Untitled",
          "description" => op["description"] || op[:description] || "",
          "op_type" => op["op_type"] || op[:op_type] || "implementation",
          "depends_on" => op["depends_on"] || op[:depends_on] || []
        }
      end)

      plan = %{name: name, summary: summary, ops: normalized_jobs}
      Format.success("Plan accepted with #{length(ops)} op(s).")
      {%{state | plan: plan, done: true}, true}
    else
      IO.puts(dim("  Sending feedback to revise the plan..."))
      {state, false}
    end
  end

  # -- Context helpers --------------------------------------------------------

  defp append_user(state, text) when is_binary(text) do
    context = ReqLLM.Context.append(state.context, ReqLLM.Context.user(text))
    %{state | context: context}
  end

  defp append_user_with_images(state, text) do
    parts = build_content_parts(text, state.pending_images)
    msg = ReqLLM.Context.user(parts)
    context = ReqLLM.Context.append(state.context, msg)
    %{state | context: context, pending_images: []}
  end

  defp build_content_parts(text, []) do
    text
  end

  defp build_content_parts(text, images) do
    image_parts =
      Enum.flat_map(images, fn path ->
        case File.read(path) do
          {:ok, data} ->
            [ReqLLM.Message.ContentPart.image(data, mime_type(path))]

          {:error, _} ->
            []
        end
      end)

    [ReqLLM.Message.ContentPart.text(text) | image_parts]
  end

  # -- Input helpers ----------------------------------------------------------

  defp read_input do
    case IO.gets(color(:green) <> "> " <> reset()) do
      :eof -> :eof
      {:error, _} -> :eof
      data -> String.trim(data)
    end
  end

  # -- Tool definitions -------------------------------------------------------

  defp build_tools do
    [
      ReqLLM.Tool.new!(
        name: "ask_choice",
        description:
          "Present a selection prompt to the user. The user navigates with arrow keys and presses enter. " <>
            "For multi=true, the user can toggle multiple items with space before confirming.",
        parameter_schema: %{
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
        },
        callback: fn _args -> {:ok, "handled"} end
      ),
      ReqLLM.Tool.new!(
        name: "submit_plan",
        description:
          "Submit the final implementation plan. Call after gathering enough information from the user.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Short mission name"},
            "summary" => %{"type" => "string", "description" => "1-2 sentence summary"},
            "ops" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "title" => %{"type" => "string"},
                  "description" => %{
                    "type" => "string",
                    "description" => "Detailed description for an AI agent to execute"
                  },
                  "op_type" => %{
                    "type" => "string",
                    "enum" => ["research", "implementation", "verification"]
                  },
                  "depends_on" => %{
                    "type" => "array",
                    "items" => %{"type" => "integer"},
                    "description" => "0-based indices of prerequisite ops"
                  }
                },
                "required" => ["title", "description", "op_type"]
              }
            }
          },
          "required" => ["name", "summary", "ops"]
        },
        callback: fn _args -> {:ok, "handled"} end
      )
    ]
  end

  # -- Codebase context -------------------------------------------------------

  defp build_codebase_context(mission) do
    sector_id = Map.get(mission, :sector_id)

    case sector_id && GiTF.Archive.get(:sectors, sector_id) do
      nil ->
        "No codebase context available."

      sector ->
        path = sector.path

        if File.dir?(path) do
          files = list_files(path, 3) |> Enum.sort() |> Enum.take(150)

          """
          Comb: #{Map.get(sector, :name, "unknown")} (#{path})

          File tree:
          #{Enum.join(files, "\n")}
          """
        else
          "Comb: #{Map.get(sector, :name, "unknown")} (#{path}, not accessible)"
        end
    end
  rescue
    _ -> "Could not read codebase context."
  end

  defp list_files(root, max_depth) do
    do_list_files(root, root, max_depth)
  end

  @skip_dirs ~w(node_modules _build deps vendor .git .gitf __pycache__ .next .cache)

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

  defp build_system_prompt(mission, codebase) do
    """
    You are an expert software architect helping plan an implementation.

    ## Your Role
    Gather requirements and create an implementation plan for: "#{mission.goal}"

    ## Codebase Context
    #{codebase}

    ## CRITICAL: You MUST use tools — do NOT ask questions as plain text

    You have two tools: `ask_choice` and `submit_plan`. You MUST use them.

    - **Every question to the user MUST use `ask_choice`**. Never write numbered lists of questions in text. Instead, call `ask_choice` once per question. You may call multiple `ask_choice` tools in a single response.
    - Each `ask_choice` must have 2-6 concrete options with `label` and `description`. Mark your recommended option with `recommended: true`.
    - Use `multi: true` when the user should pick multiple items (e.g., "which metrics to show").
    - Only use plain text for brief context before tool calls (1-2 sentences max).
    - After 2-4 exchanges, call `submit_plan` with the structured plan.

    ## Flow
    1. Respond with a brief greeting (1 sentence), then immediately call 2-3 `ask_choice` tools for your clarifying questions.
    2. Based on answers, ask follow-up `ask_choice` questions to refine scope, or call `submit_plan` when you have enough context.
    3. Be thoughtful — aim for 3-5 exchanges to fully understand what the user wants before submitting the plan. Don't rush to a plan before you understand the problem.

    ## Plan Guidelines (for `submit_plan`)
    - Break work into small, focused ops (1-3 hours each for an AI coding agent)
    - Use op_type "research" for unknowns and exploration
    - Use op_type "implementation" for coding work
    - Use op_type "verification" for testing and validation
    - Set depends_on (0-based indices) to define execution order
    - Each op description must have enough detail for an AI agent to execute independently
    """
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
