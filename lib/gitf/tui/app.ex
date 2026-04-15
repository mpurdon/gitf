defmodule GiTF.TUI.App do
  @moduledoc """
  The main TUI application module.

  Uses Ratatouille's subscription system to poll ViewModel for updates
  rather than PubSub (which doesn't integrate with the Ratatouille runtime loop).

  User chat input is sent to a headless Claude session via
  `Ratatouille.Runtime.Command`, and the response is displayed in the
  chat panel when it arrives.
  """
  @behaviour Ratatouille.App

  require Logger

  require GiTF.Ghost.Status, as: GhostStatus
  alias GiTF.TUI.Context.{Input, Chat, Activity, Plan}
  alias GiTF.TUI.{Constants, Views}
  alias Ratatouille.Runtime.{Command, Subscription}

  import Ratatouille.View
  import Ratatouille.Constants, only: [key: 1]

  @space key(:space)
  @enter key(:enter)
  @backspace key(:backspace)
  @backspace2 key(:backspace2)
  @delete key(:delete)
  @arrow_left key(:arrow_left)
  @arrow_right key(:arrow_right)
  @arrow_up key(:arrow_up)
  @arrow_down key(:arrow_down)
  @tab key(:tab)
  @pgup key(:pgup)
  @pgdown key(:pgdn)
  @f1 key(:f1)
  @f2 key(:f2)
  @f3 key(:f3)
  @f4 key(:f4)
  @f5 key(:f5)

  @impl true
  def init(_context) do
    if connected?() do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "ops")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "ghosts")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "costs")
      Phoenix.PubSub.subscribe(GiTF.PubSub, "section:alerts")
    end

    planning_mission = Application.get_env(:gitf, :tui_planning_mission)
    Application.delete_env(:gitf, :tui_planning_mission)

    model = %{
      input: Input.new(),
      chat: Chat.new(),
      activity: Activity.new(),
      plan: Plan.new(),
      busy: false,
      session_id: nil,
      chat_scroll: 0,
      # Dashboard state
      right_panel: :activity,
      ops: [],
      health: %{status: :unknown, checks: %{}, timestamp: nil},
      alerts: [],
      sync_queue: %{pending: [], active: nil, completed: []},
      runs: [],
      budget_status: [],
      backups: %{},
      agent_identities: [],
      event_store_events: [],
      stats: nil,
      refresh_count: 0,
      # Planning mode
      planning_mission: planning_mission,
      select: nil
    }

    if planning_mission do
      # Auto-start the planning conversation
      chat =
        Chat.add_message(
          model.chat,
          :system,
          "Planning: #{planning_mission.goal || planning_mission.name}"
        )

      prompt =
        "I want to plan: \"#{planning_mission.goal}\". " <>
          "Start by exploring the codebase to understand the current state, " <>
          "then ask me clarifying questions about what I need."

      model = %{model | chat: chat, busy: true, chat_scroll: 0}
      cmd = Command.new(fn -> query_claude(prompt, nil) end, :chat_response)
      {model, cmd}
    else
      model
    end
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(500, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ch}} when ch > 0 ->
        # In plan-review mode with empty input, single chars are shortcuts
        if model.plan.mode == :reviewing and model.input.text == "" do
          case List.to_string([ch]) do
            "y" ->
              %{model | plan: Plan.accept_section(model.plan)}

            "n" ->
              handle_plan_reject(model)

            "a" ->
              %{model | plan: Plan.accept_all(model.plan)}

            "q" ->
              handle_plan_cancel(model)

            char ->
              input = Input.insert_char(model.input, char)
              %{model | input: input}
          end
        else
          input = Input.insert_char(model.input, List.to_string([ch]))
          %{model | input: input}
        end

      {:event, %{key: key}} ->
        handle_key(model, key)

      {:event, %{resize: _resize}} ->
        model

      :tick ->
        count = (model[:refresh_count] || 0) + 1
        model = %{model | refresh_count: count}

        model
        |> refresh_activity()
        |> refresh_dashboard(count)

      {:chat_response, {:ok, {:switch_plan, plan_data}, _session_id}} ->
        strategy = plan_data[:strategy] || plan_data["strategy"] || "?"
        score = plan_data[:score] || plan_data["score"]
        score_str = if score, do: " (#{Float.round(score, 2)})", else: ""
        chat = Chat.add_message(model.chat, :system, "Switched to #{strategy}#{score_str} plan.")
        plan = Plan.load_plan(model.plan, plan_data)
        # Preserve candidate_index from before load_plan reset it
        plan = %{
          plan
          | candidate_index: model.plan.candidate_index,
            candidates: model.plan.candidates
        }

        %{model | chat: chat, plan: plan, busy: false, chat_scroll: chat_bottom(chat)}

      {:chat_response, {:ok, content, session_id}} ->
        sid = session_id || model.session_id
        # Check if response contains a plan block
        case parse_plan_block(content) do
          {:plan, plan_data, remaining_text} ->
            chat =
              if remaining_text != "" do
                Chat.add_message(model.chat, :assistant, remaining_text)
              else
                Chat.add_message(
                  model.chat,
                  :assistant,
                  "Plan generated. Review it in the right panel."
                )
              end

            plan = Plan.load_plan(model.plan, plan_data)

            %{
              model
              | chat: chat,
                plan: plan,
                busy: false,
                session_id: sid,
                chat_scroll: chat_bottom(chat)
            }

          :no_plan ->
            chat = Chat.add_message(model.chat, :assistant, content)
            %{model | chat: chat, busy: false, session_id: sid, chat_scroll: chat_bottom(chat)}
        end

      {:chat_response, {:error, reason}} ->
        chat = Chat.add_message(model.chat, :system, "Error: #{reason}")
        %{model | chat: chat, busy: false, chat_scroll: chat_bottom(chat)}

      # Real-time PubSub updates
      {:op_updated, _op} ->
        refresh_dashboard(model, 1)

      {:ghost_updated, _ghost} ->
        refresh_dashboard(model, 1)

      {:cost_recorded, _cost} ->
        refresh_dashboard(model, 1)

      {:alert_raised, alert} ->
        %{model | alerts: [alert | model.alerts] |> Enum.take(10)}

      _ ->
        model
    end
  end

  defp connected?, do: true

  defp handle_key(model, key) do
    plan_reviewing? = model.plan.mode == :reviewing
    input_empty? = model.input.text == ""

    case key do
      # Panel switching (F-keys)
      @f1 ->
        %{model | right_panel: :activity}

      @f2 ->
        %{model | right_panel: :pipeline}

      @f3 ->
        %{model | right_panel: :events}

      @f4 ->
        %{model | right_panel: :merges}

      @f5 ->
        %{model | right_panel: :models}

      @space ->
        input = Input.insert_char(model.input, " ")
        %{model | input: input}

      @enter ->
        if plan_reviewing? and input_empty? and Plan.all_accepted?(model.plan) do
          handle_plan_confirm(model)
        else
          submit_input(model)
        end

      key when key in [@backspace, @backspace2] ->
        input = Input.delete_char(model.input)
        %{model | input: input}

      @delete ->
        input = Input.delete_char_forward(model.input)
        %{model | input: input}

      @arrow_left ->
        input = Input.move_cursor(model.input, :left)
        %{model | input: input}

      @arrow_right ->
        input = Input.move_cursor(model.input, :right)
        %{model | input: input}

      @arrow_up ->
        cond do
          plan_reviewing? and input_empty? ->
            %{model | plan: Plan.select_prev(model.plan)}

          input_empty? ->
            # Scroll up
            %{model | chat_scroll: max(model.chat_scroll - 1, 0)}

          true ->
            input = Input.prev_history(model.input)
            %{model | input: input}
        end

      @arrow_down ->
        cond do
          plan_reviewing? and input_empty? ->
            %{model | plan: Plan.select_next(model.plan)}

          input_empty? ->
            # Scroll down
            %{model | chat_scroll: model.chat_scroll + 1}

          true ->
            input = Input.next_history(model.input)
            %{model | input: input}
        end

      @pgup ->
        %{model | chat_scroll: max(model.chat_scroll - 10, 0)}

      @pgdown ->
        %{model | chat_scroll: model.chat_scroll + 10}

      @tab ->
        if plan_reviewing? and input_empty? and Plan.candidate_count(model.plan) > 1 do
          handle_switch_candidate(model)
        else
          model
        end

      _ ->
        model
    end
  end

  # -- Dashboard refresh ---------------------------------------------------

  defp refresh_dashboard(model, count) do
    model
    |> refresh_fast()
    |> maybe_refresh_medium(count)
    |> maybe_refresh_slow(count)
    |> maybe_refresh_events(count)
  end

  # Every tick: sync queue, runs
  defp refresh_fast(model) do
    model
    |> Map.put(:sync_queue, safe_call(fn -> GiTF.Sync.Queue.status() end, model.sync_queue))
    |> Map.put(:runs, safe_call(fn -> GiTF.Run.list(status: "active") end, model.runs))
  end

  # Every 6th tick (~3s): alerts, stats
  defp maybe_refresh_medium(model, count) when rem(count, 6) == 0 do
    model
    |> Map.put(
      :alerts,
      safe_call(fn -> GiTF.Observability.Alerts.check_alerts() end, model.alerts)
    )
    |> Map.put(
      :stats,
      safe_call(fn -> GiTF.Observability.Metrics.collect_metrics() end, model.stats)
    )
  end

  defp maybe_refresh_medium(model, _count), do: model

  # Every 20th tick (~10s): health, identities, budget, backups
  defp maybe_refresh_slow(model, count) when rem(count, 20) == 0 do
    ghosts = model.activity.ghosts
    missions = model.activity.missions

    backups =
      ghosts
      |> Enum.filter(&(&1[:status] == GhostStatus.working()))
      |> Enum.reduce(%{}, fn ghost, acc ->
        case safe_call(fn -> GiTF.Backup.load(ghost[:id]) end, :error) do
          {:ok, cp} -> Map.put(acc, ghost[:id], cp)
          _ -> acc
        end
      end)

    budget_status = load_budget_status(missions)

    model
    |> Map.put(:health, safe_call(fn -> GiTF.Observability.Health.check() end, model.health))
    |> Map.put(
      :agent_identities,
      safe_call(fn -> GiTF.GhostID.list() end, model.agent_identities)
    )
    |> Map.put(:backups, backups)
    |> Map.put(:budget_status, budget_status)
  end

  defp maybe_refresh_slow(model, _count), do: model

  # Events: only when events panel is active, every 6th tick
  defp maybe_refresh_events(%{right_panel: :events} = model, count) when rem(count, 6) == 0 do
    Map.put(
      model,
      :event_store_events,
      safe_call(fn -> GiTF.EventStore.list(limit: 30) end, model.event_store_events)
    )
  end

  defp maybe_refresh_events(model, _count), do: model

  defp load_budget_status(missions) do
    missions
    |> Enum.filter(&(&1[:status] in ["active", "pending"]))
    |> Enum.map(fn q ->
      budget = safe_call(fn -> GiTF.Budget.budget_for(q[:id]) end, 0.0)
      spent = safe_call(fn -> GiTF.Budget.spent_for(q[:id]) end, 0.0)
      remaining = Float.round(budget - spent, 2)
      %{mission_id: q[:id], budget: budget, spent: spent, remaining: max(remaining, 0.0)}
    end)
  rescue
    _ -> []
  end

  # -- Plan mode handlers ----------------------------------------------------

  defp handle_plan_confirm(model) do
    specs = Plan.to_confirmed_specs(model.plan)
    mission_id = model.plan.mission_id

    # If launched from CLI planning, store the result for the CLI to pick up
    if model.planning_mission do
      plan_result = %{
        name: model.plan.goal || "",
        summary: "",
        ops:
          Enum.map(specs, fn spec ->
            %{
              "title" => spec["title"] || spec[:title] || "",
              "description" => spec["description"] || spec[:description] || "",
              "op_type" => spec["op_type"] || spec[:op_type] || "implementation",
              "depends_on" => spec["depends_on_indices"] || spec[:depends_on_indices] || []
            }
          end)
      }

      Application.put_env(:gitf, :tui_plan_result, {:ok, plan_result})
    end

    chat = Chat.add_message(model.chat, :system, "Confirming plan...")
    plan = %{model.plan | mode: :confirmed}
    model = %{model | chat: chat, plan: plan, busy: true, chat_scroll: chat_bottom(chat)}

    cmd =
      Command.new(
        fn ->
          case GiTF.Client.confirm_plan(mission_id, specs) do
            {:ok, data} ->
              ops = data[:jobs_created] || 0
              {:ok, "Plan confirmed. #{ops} op(s) created for mission #{mission_id}.", nil}

            {:error, reason} ->
              # Fallback to local if not remote
              if !GiTF.Client.remote?() do
                {:ok, ops} = GiTF.Major.Planner.create_jobs_from_specs(mission_id, specs)
                GiTF.Missions.store_artifact(mission_id, "planning", specs)
                {:ok, "Plan confirmed. #{length(ops)} op(s) created.", nil}
              else
                {:error, inspect(reason)}
              end
          end
        end,
        :chat_response
      )

    {model, cmd}
  end

  defp handle_plan_reject(model) do
    plan = Plan.reject_section(model.plan)
    section = Enum.at(plan.sections, plan.selected)
    title = if section, do: section.title, else: "this section"

    chat =
      Chat.add_message(model.chat, :system, "Rejected: #{title}. Type feedback for revision.")

    %{model | plan: plan, chat: chat, chat_scroll: chat_bottom(chat)}
  end

  defp handle_plan_cancel(model) do
    plan = Plan.dismiss(model.plan)
    chat = Chat.add_message(model.chat, :system, "Plan review cancelled.")
    %{model | plan: plan, chat: chat, chat_scroll: chat_bottom(chat)}
  end

  defp handle_switch_candidate(model) do
    plan = Plan.next_candidate(model.plan)
    mission_id = plan.mission_id

    case Plan.current_strategy(plan) do
      {strategy, _score} ->
        chat = Chat.add_message(model.chat, :system, "Switching to #{strategy} plan...")
        model = %{model | plan: plan, chat: chat, busy: true, chat_scroll: chat_bottom(chat)}

        cmd =
          Command.new(
            fn ->
              result =
                if GiTF.Client.remote?() do
                  GiTF.Client.select_plan_candidate(mission_id, strategy)
                else
                  # Local mode: find candidate from mission record
                  quest_record = GiTF.Archive.get(:missions, mission_id)

                  candidates =
                    if quest_record, do: Map.get(quest_record, :plan_candidates, []), else: []

                  case Enum.find(candidates, fn c -> (c[:strategy] || c.strategy) == strategy end) do
                    nil ->
                      {:error, "candidate not found"}

                    candidate ->
                      if quest_record do
                        updated = Map.put(quest_record, :draft_plan, candidate)
                        GiTF.Archive.put(:missions, updated)
                      end

                      {:ok, candidate}
                  end
                end

              case result do
                {:ok, plan_data} ->
                  {:ok, {:switch_plan, plan_data}, nil}

                {:error, reason} ->
                  {:error, inspect(reason)}
              end
            end,
            :chat_response
          )

        {model, cmd}

      _ ->
        model
    end
  end

  # Estimate scroll offset to keep latest messages visible.
  # Each message is ~2 lines on average (prefix + wrapped content).
  defp chat_bottom(chat) do
    # Heuristic: count messages and assume avg 4 lines each
    # This ensures we scroll far enough to see the latest message even if it wraps
    max(length(chat.history) * 4 - 5, 0)
  end

  defp debug(msg) do
    File.write("/tmp/gitf_tui_debug.log", "[#{DateTime.utc_now()}] #{msg}\n", [:append])
  end

  defp submit_input(model) do
    {input, text} = Input.submit(model.input)

    if text == "" do
      %{model | input: input}
    else
      debug("submit: #{String.slice(text, 0, 80)}")
      chat = Chat.add_message(model.chat, :user, text)
      session_id = model.session_id
      model = %{model | input: input, chat: chat, busy: true, chat_scroll: chat_bottom(chat)}
      cmd = Command.new(fn -> query_claude(text, session_id) end, :chat_response)
      {model, cmd}
    end
  end

  defp query_claude(text, session_id) do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      query_via_api(text, session_id)
    else
      query_via_cli(text, session_id)
    end
  catch
    kind, reason ->
      debug("crashed: #{kind}: #{inspect(reason)}")
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp query_via_api(text, _session_id) do
    cwd =
      case GiTF.gitf_dir() do
        {:ok, root} -> root
        _ -> File.cwd!()
      end

    system_prompt = build_system_prompt(cwd)
    debug("API mode query: #{String.slice(text, 0, 80)}")

    case GiTF.Runtime.AgentLoop.run(text, cwd,
           system_prompt: system_prompt,
           tool_set: :major,
           max_iterations: 20,
           max_tokens: 8192
         ) do
      {:ok, result} ->
        content = Map.get(result, :text, "")
        sid = result[:session_id] || extract_session_from_events(result[:events])
        {:ok, content, sid}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp extract_session_from_events(nil), do: nil

  defp extract_session_from_events(events) do
    Enum.find_value(events, fn
      %{"type" => "system", "session_id" => sid} -> sid
      _ -> nil
    end)
  end

  defp query_via_cli(text, session_id) do
    cwd =
      case GiTF.gitf_dir() do
        {:ok, root} -> root
        _ -> File.cwd!()
      end

    system_prompt = build_system_prompt(cwd)

    debug("spawning headless for: #{String.slice(text, 0, 80)} session=#{inspect(session_id)}")

    case spawn_claude_with_closed_stdin(text, cwd, system_prompt, session_id) do
      {:ok, port} ->
        debug("port spawned: #{inspect(port)}")
        result = collect_port_output(port, [])
        debug("result: #{inspect(result, limit: 200)}")
        result

      {:error, reason} ->
        debug("spawn failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp build_system_prompt(cwd) do
    ghosts =
      try do
        GiTF.Archive.all(:ghosts)
      rescue
        _ -> []
      end

    missions =
      try do
        GiTF.Archive.all(:missions)
      rescue
        _ -> []
      end

    ops =
      try do
        GiTF.Archive.all(:ops)
      rescue
        _ -> []
      end

    # Only show active ghosts in context — crashed/stopped are noise
    active_ghosts =
      Enum.filter(ghosts, fn b ->
        (b[:status] || b[:state]) in [GhostStatus.working(), GhostStatus.provisioning()]
      end)

    ghost_summary =
      if active_ghosts == [],
        do: "None active",
        else:
          Enum.map_join(active_ghosts, "\n", fn b ->
            "  - #{b[:id] || b.id}: #{b[:status] || b[:state] || "unknown"} (op: #{b[:op_id] || "none"})"
          end)

    quest_summary =
      if missions == [],
        do: "None",
        else:
          Enum.map_join(missions, "\n", fn q ->
            phase = q[:current_phase] || q[:status] || "unknown"
            "  - #{q[:id] || q.id}: #{q[:name] || q[:goal] || "unnamed"} [#{phase}]"
          end)

    active_jobs = Enum.reject(ops, fn j -> j[:status] in ["done"] end)

    job_summary =
      if active_jobs == [],
        do: "All done",
        else:
          Enum.map_join(Enum.take(active_jobs, 10), "\n", fn j ->
            "  - #{j[:id] || j.id}: #{j[:title] || "untitled"} [#{j[:status] || "unknown"}]"
          end)

    """
    You are the Major's assistant running inside the GiTF TUI dashboard.
    You help the user monitor and control their autonomous coding swarm.
    Keep responses brief — this is a terminal chat panel, not a document.
    IMPORTANT: Do NOT use markdown, tables, bold, headers, or emojis. Plain text only.

    GiTF concepts:
    - Sector: a managed git repository (has id, name, path, repo_url)
    - Quest: a high-level objective broken into phases (research > requirements > design > review > planning > implementation > validation)
    - Job: a discrete unit of work within a mission
    - Ghost: an autonomous AI coding agent that works on ops in isolated git worktrees (shells)
    - Link: a message between agents (like ghost-to-queen status updates)
    - Major: the central coordinator that manages missions, spawns ghosts, handles retries
    - Tachikoma: autonomous watchdog that monitors quality

    CLI commands the user can run outside the TUI:
    - section mission new "goal" --sector <name>  (create a mission)
    - section sector add <path>                 (register a repository)
    - section sector list                       (list sectors)
    - section ghost list                        (list ghosts)
    - section mission list                      (list missions)
    - section mission show <id>                 (show mission details)
    - section status                          (overall section status)

    Workspace: #{cwd}

    Current section state:
    Ghosts: #{ghost_summary}
    Quests: #{quest_summary}
    Jobs: #{job_summary}

    You have full access to the workspace to read files and execute commands.
    You can run section CLI commands directly to create missions, spawn ghosts, etc.
    Act autonomously — the user wants a dark factory, not hand-holding.

    STRUCTURED QUESTIONS: When you need to ask the user clarifying questions,
    wrap them in this exact format so the TUI can render them nicely:

    <<<QUESTIONS
    {"preamble": "Brief context about why you're asking", "questions": ["First question?", "Second question?", "Third question?"]}
    QUESTIONS>>>

    Only use this format for multi-question clarification. For simple yes/no or single questions, just ask normally in plain text.

    STRUCTURED PLANS: When the user asks you to plan a mission or you generate a plan,
    wrap the plan in this exact format so the TUI can display it for review:

    <<<PLAN
    {"mission_id": "msn-xxx", "goal": "What we're building", "tasks": [
      {"title": "Task title", "description": "Details", "target_files": ["file.py"], "model_recommendation": "sonnet"},
      {"title": "Another task", "description": "More details", "target_files": [], "depends_on_indices": [0], "model_recommendation": "sonnet"}
    ]}
    PLAN>>>

    Use this format when generating implementation plans. The user will review each task
    and can accept, reject, or ask questions about individual sections.
    """
  end

  defp spawn_claude_with_closed_stdin(prompt, cwd, system_prompt, _session_id) do
    case GiTF.Runtime.Claude.find_executable() do
      {:ok, claude_path} ->
        args = [
          "--print",
          "--dangerously-skip-permissions",
          "--verbose",
          "--output-format",
          "stream-json",
          "--system-prompt",
          system_prompt,
          prompt
        ]

        # Spawn through shell with < /dev/null so Claude gets EOF on stdin
        # immediately instead of hanging waiting for the Erlang port's pipe.
        escaped_args =
          Enum.map_join(args, " ", fn a ->
            "'" <> String.replace(a, "'", "'\\''") <> "'"
          end)

        cmd = "#{claude_path} #{escaped_args} < /dev/null"

        port =
          Port.open({:spawn, cmd}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:cd, cwd},
            {:env, [{~c"CLAUDECODE", false}]}
          ])

        {:ok, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        debug("port data: #{byte_size(data)} bytes")
        collect_port_output(port, [acc, data])

      {^port, {:exit_status, code}} ->
        debug("port exit: #{code}")
        raw = IO.iodata_to_binary(acc)
        {content, session_id} = extract_response(raw)

        if code == 0 do
          {:ok, content, session_id}
        else
          if content != "",
            do: {:ok, content, session_id},
            else: {:error, "Claude exited with code #{code}"}
        end

      other ->
        debug("port unexpected msg: #{inspect(other, limit: 200)}")
        collect_port_output(port, acc)
    after
      60_000 ->
        debug("port timeout after 60s, closing")
        Port.close(port)
        raw = IO.iodata_to_binary(acc)
        {content, session_id} = extract_response(raw)

        if content != "",
          do: {:ok, content, session_id},
          else: {:error, "Timed out waiting for Claude"}
    end
  end

  defp extract_response(raw) do
    # Claude --print --verbose --output-format stream-json outputs JSON lines.
    # Parse the result text and session_id.
    lines = String.split(raw, "\n")

    result_text =
      Enum.find_value(lines, fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
            String.trim(result)

          _ ->
            nil
        end
      end)

    session_id =
      Enum.find_value(lines, fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "session_id" => sid}} when is_binary(sid) -> sid
          _ -> nil
        end
      end)

    text =
      case result_text do
        nil -> raw |> String.trim() |> String.slice(0, 2000)
        "" -> raw |> String.trim() |> String.slice(0, 2000)
        t -> t
      end

    # Check if the response contains a structured questions block
    content = parse_questions(text)
    {content, session_id}
  end

  defp parse_questions(text) do
    case Regex.run(~r/<<<QUESTIONS\s*\n(.*?)\nQUESTIONS>>>/s, text) do
      [_full, json] ->
        case Jason.decode(json) do
          {:ok, %{"preamble" => preamble, "questions" => questions}} when is_list(questions) ->
            {:questions, preamble, questions}

          _ ->
            text
        end

      _ ->
        text
    end
  end

  defp parse_plan_block(content) when is_binary(content) do
    case Regex.run(~r/<<<PLAN\s*\n(.*?)\nPLAN>>>/s, content) do
      [full, json] ->
        case Jason.decode(json) do
          {:ok, plan_data} when is_map(plan_data) ->
            remaining = String.replace(content, full, "") |> String.trim()
            {:plan, plan_data, remaining}

          _ ->
            :no_plan
        end

      _ ->
        :no_plan
    end
  end

  defp parse_plan_block(_), do: :no_plan

  defp refresh_activity(model) do
    ghosts =
      try do
        GiTF.Archive.all(:ghosts)
      rescue
        _ -> []
      end

    missions =
      try do
        GiTF.Archive.all(:missions)
      rescue
        _ -> []
      end

    ops =
      try do
        GiTF.Archive.all(:ops)
      rescue
        _ -> []
      end

    # Reap dead ghosts — detect ghosts marked "working" but actually finished/dead
    # Returns list of {ghost_id, :done | :failed, summary} events
    reap_events = reap_dead_bees(ghosts, ops)

    # Add reap events to chat
    model =
      Enum.reduce(reap_events, model, fn
        {ghost_id, :done, summary}, m ->
          job_title =
            Enum.find_value(ops, "unknown", fn j -> if j[:ghost_id] == ghost_id, do: j[:title] end)

          msg = "#{ghost_id} finished: #{job_title}\n#{summary}"
          %{m | chat: Chat.add_message(m.chat, :system, msg), chat_scroll: chat_bottom(m.chat)}

        {ghost_id, :failed, reason}, m ->
          msg = "#{ghost_id} failed: #{reason}"
          %{m | chat: Chat.add_message(m.chat, :system, msg), chat_scroll: chat_bottom(m.chat)}
      end)

    # Re-read after reaping
    ghosts =
      try do
        GiTF.Archive.all(:ghosts)
      rescue
        _ -> []
      end

    # Build op_id -> mission_id lookup
    job_quest_map = Map.new(ops, fn j -> {j[:id], j[:mission_id]} end)

    # Filter to active ghosts and attach mission_id
    active_ghosts =
      ghosts
      |> Enum.filter(fn b ->
        (b[:status] || b[:state]) in [GhostStatus.working(), GhostStatus.provisioning()]
      end)
      |> Enum.map(fn b -> Map.put(b, :mission_id, job_quest_map[b[:op_id]]) end)

    ghost_logs = read_ghost_logs(active_ghosts)

    activity =
      model.activity
      |> Activity.update_bees(active_ghosts)
      |> Activity.update_quests(missions)
      |> Activity.update_ghost_logs(ghost_logs)

    %{model | activity: activity, ops: ops}
  end

  defp reap_dead_bees(ghosts, _jobs) do
    case GiTF.gitf_dir() do
      {:ok, root} ->
        run_dir = Path.join([root, ".gitf", "run"])

        ghosts
        |> Enum.filter(fn b -> (b[:status] || b[:state]) == GhostStatus.working() end)
        |> Enum.flat_map(fn ghost ->
          log_path = Path.join(run_dir, "#{ghost[:id]}.log")
          script_path = Path.join(run_dir, "#{ghost[:id]}.sh")

          cond do
            ghost_log_completed?(log_path) ->
              debug("reaper: ghost #{ghost[:id]} completed (result in log)")
              summary = ghost_log_last_message(log_path)
              mark_bee_done(ghost)
              [{ghost[:id], :done, summary}]

            not script_running?(script_path) and File.exists?(log_path) ->
              if ghost_log_has_error?(log_path) do
                debug("reaper: ghost #{ghost[:id]} failed (process dead, error in log)")
                mark_bee_failed(ghost, "Process died")
                [{ghost[:id], :failed, "Process died"}]
              else
                log_age = log_file_age_seconds(log_path)

                if log_age > 120 do
                  debug("reaper: ghost #{ghost[:id]} stale (log #{log_age}s old, no process)")
                  mark_bee_failed(ghost, "Process disappeared")
                  [{ghost[:id], :failed, "Process disappeared"}]
                else
                  []
                end
              end

            true ->
              []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp ghost_log_last_message(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.to_list()
      |> Enum.reverse()
      |> Enum.find_value("(no summary)", fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
            String.trim(result) |> String.slice(0, 200)

          _ ->
            nil
        end
      end)
    else
      "(no log)"
    end
  rescue
    _ -> "(error reading log)"
  end

  defp ghost_log_completed?(path) do
    if File.exists?(path) do
      # Check last few lines for a "result" type (Claude finished successfully)
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.to_list()
      |> Enum.take(-3)
      |> Enum.any?(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result"}} -> true
          _ -> false
        end
      end)
    else
      false
    end
  rescue
    _ -> false
  end

  defp ghost_log_has_error?(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.any?(fn line ->
        String.contains?(line, "Error:") or String.contains?(line, "cannot be launch")
      end)
    else
      false
    end
  rescue
    _ -> false
  end

  defp script_running?(script_path) do
    # Check if any process is running this script
    case System.cmd("pgrep", ["-f", script_path], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp log_file_age_seconds(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp mark_bee_done(ghost) do
    try do
      GiTF.Ghosts.complete(ghost[:id])

      # Tell Major to advance the mission
      if ghost[:op_id] do
        case Process.whereis(GiTF.Major) do
          nil ->
            :ok

          _pid ->
            try do
              {:ok, op} = GiTF.Ops.get(ghost[:op_id])
              GiTF.Major.Orchestrator.advance_quest(op.mission_id)
            rescue
              _ -> :ok
            end
        end
      end
    rescue
      _ -> :ok
    end
  end

  defp mark_bee_failed(ghost, reason) do
    try do
      GiTF.Ghosts.fail(ghost[:id], reason)
    rescue
      _ -> :ok
    end
  end

  defp read_ghost_logs(ghosts) do
    case GiTF.gitf_dir() do
      {:ok, root} ->
        run_dir = Path.join([root, ".gitf", "run"])

        ghosts
        |> Enum.filter(fn b ->
          (b[:status] || b[:state]) in [GhostStatus.working(), GhostStatus.provisioning()]
        end)
        |> Map.new(fn ghost ->
          log_path = Path.join(run_dir, "#{ghost[:id]}.log")
          lines = tail_file(log_path, 3)
          {ghost[:id], lines}
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp tail_file(path, n) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.to_list()
      |> Enum.take(-n)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "tool_use", "name" => tool} = event} ->
            file = get_in(event, ["input", "file_path"]) || ""
            cmd = get_in(event, ["input", "command"]) || ""
            detail = if file != "", do: file, else: String.slice(cmd, 0, 40)
            [String.slice("#{tool} #{detail}", 0, 60)]

          {:ok, %{"type" => "tool_result"} = event} ->
            output = get_in(event, ["output"]) || ""
            if String.contains?(output, "Error"), do: [String.slice(output, 0, 60)], else: []

          _ ->
            []
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      _, _ -> default
    end
  end

  # -- Render ---------------------------------------------------------------

  @impl true
  def render(model) do
    view top_bar: status_bar(model), bottom_bar: input_bar(model) do
      row do
        column size: 8 do
          Views.Chat.render(model)
        end

        column size: 4 do
          render_right_panel(model)
        end
      end
    end
  end

  defp render_right_panel(model) do
    if model.plan.mode in [:reviewing, :confirmed] do
      Views.Plan.render(model)
    else
      case model.right_panel do
        :activity -> Views.Activity.render(model)
        :pipeline -> Views.Pipeline.render(model)
        :events -> Views.Events.render(model)
        :merges -> Views.Syncs.render(model)
        :models -> Views.Models.render(model)
        _ -> Views.Activity.render(model)
      end
    end
  end

  defp status_bar(model) do
    health = model[:health] || %{checks: %{}}
    alerts = model[:alerts] || []
    mq = model[:sync_queue] || %{pending: [], active: nil}
    stats = model[:stats]

    alert_count = length(alerts)
    alert_color = if alert_count > 0, do: :yellow, else: :white
    pending_count = length(mq[:pending] || [])
    mq_color = if pending_count > 0, do: :yellow, else: :white

    active_text =
      case mq[:active] do
        nil ->
          ""

        active ->
          id = Map.get(active, :op_id) || Map.get(active, "op_id")
          " >>" <> (id |> to_string() |> String.slice(0, 8))
      end

    {_kpi_text, kpi_parts} = build_kpi_parts(stats)

    bar do
      label do
        text(content: "Health:", color: :white)

        for {name, status} <- health[:checks] || %{} do
          text(content: " #{health_char(status)}", color: health_color(status))
          text(content: "#{short_check_name(name)}", color: :white)
        end

        text(content: " | ", color: :white)
        text(content: "Alerts:#{alert_count}", color: alert_color)
        text(content: " | ", color: :white)
        text(content: "MQ:#{pending_count}", color: mq_color)
        text(content: active_text, color: :blue)

        for {content, color} <- kpi_parts do
          text(content: content, color: color)
        end

        text(content: " | ", color: :white)
        text(content: "F1-F5:panels", color: :white)
      end
    end
  end

  defp build_kpi_parts(nil), do: {"", []}

  defp build_kpi_parts(stats) do
    parts = [
      {" | ", :white},
      {"B:#{stats.ghosts.active}", :cyan},
      {" J:#{stats.ops.running}", :yellow},
      {" $#{Float.round(stats.costs.total, 2)}", :red}
    ]

    parts =
      if stats.quality.count > 0 do
        parts ++ [{" Q:#{Float.round(stats.quality.average * 100, 0)}%", :green}]
      else
        parts
      end

    {"", parts}
  end

  defp health_char(:ok), do: "o"
  defp health_char(:warning), do: "!"
  defp health_char(:error), do: "x"
  defp health_char(_), do: "?"

  defp health_color(:ok), do: :green
  defp health_color(:warning), do: :yellow
  defp health_color(:error), do: :red
  defp health_color(_), do: :white

  defp short_check_name(:pubsub), do: "P"
  defp short_check_name(:store), do: "S"
  defp short_check_name(:disk), do: "D"
  defp short_check_name(:memory), do: "M"
  defp short_check_name(:missions), do: "Q"
  defp short_check_name(:model_api), do: "A"
  defp short_check_name(:git), do: "G"
  defp short_check_name(name), do: name |> to_string() |> String.first() |> String.upcase()

  defp input_bar(%{input: input, busy: busy}) do
    {before_cursor, at_cursor, after_cursor} =
      Views.Input.split_at_cursor(input.text, input.cursor)

    prompt = if busy, do: "... ", else: Constants.prompt_symbol()
    prompt_color = if busy, do: :yellow, else: Constants.color_prompt()

    bar do
      label do
        text(content: prompt, color: prompt_color)
        text(content: before_cursor)
        text(content: at_cursor, attributes: [:reverse])
        text(content: after_cursor)
      end
    end
  end
end
