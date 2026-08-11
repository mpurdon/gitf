defmodule GiTF.Studio.Session do
  @moduledoc """
  One planning-studio conversation: the discussion phase that turns "what
  should we build?" into an approved `GiTF.Project`.

  The spine is **tool-calls-as-events**: the planner LLM never renders UI —
  it calls structured tools (`add_decision`, `upsert_module`,
  `upsert_roadmap_item`, `generate_mockups`, ...). Each call becomes a
  **proposal** (a "ghost card") in session state, broadcast over PubSub so
  `StudioLive` animates it in. Nothing enters the plan until the user
  confirms the card — musing aloud (or, later, over voice) must not mutate
  the plan. Confirmations/dismissals are folded back into the conversation
  as user messages on the next turn.

  LLM calls run in a `Task` so the server stays responsive to UI events;
  mockup variants are generated concurrently by a fast model and attached to
  the session as versioned artifacts.

  Sessions are ephemeral (not persisted) until approval, which creates the
  project via `GiTF.Project.create/1` + `activate/1` — the same path the CLI
  and API use.
  """

  use GenServer, restart: :temporary
  require Logger

  alias GiTF.Runtime.{LLMClient, ModelResolver}
  alias GiTF.Studio.Tools

  @topic_prefix "studio:session:"
  @max_transcript 200

  defstruct id: nil,
            phase: "brief",
            status: :idle,
            transcript: [],
            brief: %{
              vision: nil,
              parti: nil,
              decisions: [],
              constraints: [],
              open_questions: []
            },
            modules: %{},
            edges: [],
            roadmap: %{},
            mockups: [],
            storyboards: [],
            proposals: %{},
            feedback_queue: [],
            proposal_seq: 0,
            model: nil,
            context: nil,
            project_id: nil,
            llm_task: nil

  # -- Client API --------------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Start a new studio session under the session supervisor."
  def start_session(opts \\ []) do
    id = "std-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    case DynamicSupervisor.start_child(
           GiTF.Studio.SessionSupervisor,
           {__MODULE__, Keyword.put(opts, :id, id)}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  def alive?(id), do: Registry.lookup(GiTF.Registry, {__MODULE__, id}) != []

  def get_state(id), do: GenServer.call(via(id), :get_state)

  @doc "User sent a chat message."
  def user_message(id, text), do: GenServer.cast(via(id), {:user_message, text})

  @doc "User confirmed a proposal card — it merges into the plan."
  def confirm_proposal(id, proposal_id),
    do: GenServer.cast(via(id), {:resolve_proposal, proposal_id, :confirm})

  @doc "User dismissed a proposal card."
  def dismiss_proposal(id, proposal_id),
    do: GenServer.cast(via(id), {:resolve_proposal, proposal_id, :dismiss})

  @doc "User picked one scheme from a propose_schemes card (three-schemes ritual)."
  def choose_scheme(id, proposal_id, scheme_name),
    do: GenServer.cast(via(id), {:choose_scheme, proposal_id, scheme_name})

  @doc """
  Approve the session's plan: creates the project (source "studio"), resolves
  the sector (`{:existing, id_or_name}` | `{:new, name}`), and activates it.
  """
  def approve(id, sector_spec), do: GenServer.call(via(id), {:approve, sector_spec}, 30_000)

  @doc """
  Execute a studio tool on behalf of a voice session (same toolset, same
  proposal semantics — speaking builds the same board). Returns
  `{:ok, result_text}` for the voice model's tool response.
  """
  def run_tool(id, name, args), do: GenServer.call(via(id), {:run_tool, name, args})

  @doc "Append a voice transcript line to the session transcript."
  def voice_transcript(id, role, text),
    do: GenServer.cast(via(id), {:voice_transcript, role, text})

  @doc "PubSub topic carrying this session's state updates."
  def topic(id), do: @topic_prefix <> id

  defp via(id), do: {:via, Registry, {GiTF.Registry, {__MODULE__, id}}}

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    GiTF.Runtime.Keys.load()

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      model: opts[:model] || ModelResolver.resolve("opus"),
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(Tools.system_prompt()),
          ReqLLM.Context.user(
            opts[:seed] ||
              "I want to plan a new software project. Interview me — start with the broad questions."
          )
        ])
    }

    {:ok, kick_llm(state)}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, public_state(state), state}

  def handle_call({:run_tool, name, args}, _from, state) do
    {state, result} = handle_tool(state, %{name: name, arguments: args})
    broadcast(state)
    {:reply, {:ok, result}, state}
  end

  def handle_call({:approve, sector_spec}, _from, state) do
    with {:ok, project} <- create_project(state),
         {:ok, project} <- resolve_sector(project, sector_spec),
         {:ok, project} <- GiTF.Project.activate(project.id) do
      state = %{state | project_id: project.id, phase: "approved"}
      broadcast(state)
      {:reply, {:ok, project}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:user_message, text}, state) do
    state =
      state
      |> add_transcript(:user, text)
      |> flush_feedback(text)
      |> kick_llm()

    {:noreply, state}
  end

  def handle_cast({:voice_transcript, role, text}, state) do
    state = add_transcript(state, role, text)
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:choose_scheme, proposal_id, scheme_name}, state) do
    case Map.pop(state.proposals, proposal_id) do
      {%{tool: "propose_schemes", args: args}, rest} ->
        axis = args["axis"] || "direction"

        scheme =
          (args["schemes"] || [])
          |> Enum.find(%{}, &((&1["name"] || &1[:name]) == scheme_name))

        thesis = scheme["thesis"] || scheme[:thesis] || ""
        decision = "#{axis}: chose \"#{scheme_name}\" — #{thesis}"

        state =
          %{state | proposals: rest}
          |> update_brief_list(:decisions, decision)
          |> queue_feedback("Chose scheme \"#{scheme_name}\" (#{axis}). Proceed with it.")

        broadcast(state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:resolve_proposal, proposal_id, action}, state) do
    case Map.pop(state.proposals, proposal_id) do
      {nil, _} ->
        {:noreply, state}

      {proposal, rest} ->
        state = %{state | proposals: rest}

        state =
          case action do
            :confirm ->
              state
              |> apply_proposal(proposal)
              |> queue_feedback("Confirmed: #{describe(proposal)}")

            :dismiss ->
              queue_feedback(state, "Dismissed (do not re-propose without new information): #{describe(proposal)}")
          end

        broadcast(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, {:llm_result, result}}, %{llm_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | llm_task: nil, status: :idle}

    state =
      case result do
        {:ok, response} -> handle_response(state, response)
        {:error, reason} -> llm_error(state, reason)
      end

    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{llm_task: %{ref: ref}} = state) do
    state = llm_error(%{state | llm_task: nil, status: :idle}, reason)
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:mockup_ready, mockup}, state) do
    state = %{state | mockups: state.mockups ++ [mockup]}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- LLM loop ----------------------------------------------------------------

  defp kick_llm(%{llm_task: task} = state) when task != nil, do: state

  defp kick_llm(state) do
    context = state.context
    model = state.model

    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        {:llm_result,
         LLMClient.generate_text(model, context,
           tools: Tools.all(),
           temperature: 0.7,
           max_tokens: 8192
         )}
      end)

    state = %{state | llm_task: task, status: :thinking}
    broadcast(state)
    state
  end

  defp handle_response(state, response) do
    classified = ReqLLM.Response.classify(response)
    state = %{state | context: response.context}

    state =
      case classified.text do
        text when is_binary(text) and text != "" -> add_transcript(state, :assistant, text)
        _ -> state
      end

    case classified.type do
      :final_answer ->
        state

      :tool_calls ->
        {state, results} =
          Enum.reduce(classified.tool_calls, {state, []}, fn tc, {s, acc} ->
            {s, result} = handle_tool(s, tc)
            {s, acc ++ [{tc, result}]}
          end)

        context =
          Enum.reduce(results, state.context, fn {tc, result}, ctx ->
            ReqLLM.Context.append(ctx, ReqLLM.Context.tool_result(tc.id, result))
          end)

        kick_llm(%{state | context: context})
    end
  end

  defp llm_error(state, reason) do
    Logger.warning("Studio session #{state.id} LLM error: #{inspect(reason, limit: 20)}")
    add_transcript(state, :system, "The planner hit an error (#{summarize_error(reason)}). Say something to retry.")
  end

  defp summarize_error(%{status: status}) when is_integer(status), do: "HTTP #{status}"
  defp summarize_error(reason), do: inspect(reason, limit: 10) |> String.slice(0, 120)

  # -- Tool handling -------------------------------------------------------------

  defp handle_tool(state, %{name: "generate_mockups", arguments: args}) do
    target = arg(args, "target") || "main screen"
    briefs = arg(args, "style_briefs") || ["clean and minimal", "bold and dense"]
    state = spawn_mockups(state, target, Enum.take(briefs, 3))

    {state,
     "Generating #{length(Enum.take(briefs, 3))} mockup variant(s) for \"#{target}\" — they will appear in the gallery shortly. Continue the conversation."}
  end

  defp handle_tool(state, %{name: name, arguments: args}) when is_map(args) do
    if name in Tools.proposal_tools() do
      proposal = %{
        id: "prp-#{state.proposal_seq}",
        tool: name,
        args: stringify(args),
        at: DateTime.utc_now()
      }

      state = %{
        state
        | proposals: Map.put(state.proposals, proposal.id, proposal),
          proposal_seq: state.proposal_seq + 1
      }

      broadcast(state)

      {state,
       "Recorded as pending card #{proposal.id}; the user confirms or dismisses it in the UI. Don't wait — continue."}
    else
      {state, "Unknown tool: #{name}"}
    end
  end

  # Confirmed proposals merge into the plan state.
  defp apply_proposal(state, %{tool: "add_decision", args: args}),
    do: update_brief_list(state, :decisions, args["text"])

  defp apply_proposal(state, %{tool: "add_constraint", args: args}),
    do: update_brief_list(state, :constraints, args["text"])

  defp apply_proposal(state, %{tool: "add_open_question", args: args}),
    do: update_brief_list(state, :open_questions, args["text"])

  defp apply_proposal(state, %{tool: "resolve_question", args: args}) do
    q = args["text"]
    update_in(state.brief.open_questions, &Enum.reject(&1, fn x -> x == q end))
  end

  defp apply_proposal(state, %{tool: "set_vision", args: args}),
    do: put_in(state.brief.vision, args["text"])

  defp apply_proposal(state, %{tool: "set_parti", args: args}),
    do: put_in(state.brief.parti, args["text"])

  defp apply_proposal(state, %{tool: "upsert_module", args: args}) do
    id = args["id"]

    module = %{
      id: id,
      label: args["label"] || id,
      effort: args["effort"] || "m",
      note: args["note"]
    }

    %{state | modules: Map.put(state.modules, id, module)}
  end

  defp apply_proposal(state, %{tool: "upsert_edge", args: args}) do
    edge = %{
      from: args["from"],
      to: args["to"],
      kind: args["kind"] || "depends_on"
    }

    %{state | edges: Enum.uniq([edge | state.edges])}
  end

  defp apply_proposal(state, %{tool: "upsert_roadmap_item", args: args}) do
    id = args["id"]

    item = %{
      id: id,
      title: args["title"] || id,
      goal: args["goal"] || "",
      depends_on: args["depends_on"] || []
    }

    %{state | roadmap: Map.put(state.roadmap, id, item)}
  end

  # Phase gate: confirming the card IS the sign-off.
  defp apply_proposal(state, %{tool: "set_phase", args: args}) do
    case args["phase"] do
      phase when phase in ~w(brief concept roadmap review) -> %{state | phase: phase}
      _ -> state
    end
  end

  defp apply_proposal(state, %{tool: "propose_storyboard", args: args}) do
    storyboard = %{
      title: args["title"] || "Journey",
      panels: args["panels"] || [],
      at: DateTime.utc_now()
    }

    %{state | storyboards: state.storyboards ++ [storyboard]}
  end

  # Schemes are resolved by choose_scheme/3, not by plain confirmation —
  # confirming the card just accepts the framing without picking.
  defp apply_proposal(state, %{tool: "propose_schemes"}), do: state

  defp apply_proposal(state, _), do: state

  defp update_brief_list(state, key, text) when is_binary(text) do
    update_in(state.brief[key], &Enum.uniq(&1 ++ [text]))
  end

  defp update_brief_list(state, _key, _), do: state

  defp describe(%{tool: tool, args: args}) do
    detail = args["text"] || args["title"] || args["label"] || args["id"] || ""
    "#{tool} #{String.slice(to_string(detail), 0, 120)}"
  end

  # -- Mockups -------------------------------------------------------------------

  defp spawn_mockups(state, target, briefs) do
    session = self()
    version = length(state.mockups)
    mockup_model = mockup_model()
    brief_context = brief_summary(state)

    briefs
    |> Enum.with_index()
    |> Enum.each(fn {style, idx} ->
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        case generate_mockup_html(mockup_model, target, style, brief_context) do
          {:ok, html} ->
            send(session, {:mockup_ready,
             %{
               id: "mck-#{version + idx}",
               target: target,
               style: style,
               html: html,
               at: DateTime.utc_now()
             }})

          {:error, reason} ->
            Logger.warning("Studio mockup generation failed: #{inspect(reason, limit: 10)}")
        end
      end)
    end)

    state
  end

  defp generate_mockup_html(model, target, style, brief_context) do
    prompt = """
    Generate a single self-contained HTML mockup of: #{target}

    Style direction: #{style}

    Product context (decided so far — honor these):
    #{brief_context}

    Rules: one complete HTML document; ALL CSS inline in a <style> tag; no
    external resources (no CDN, fonts, images — use CSS shapes/emoji); no
    JavaScript; realistic placeholder content, not lorem ipsum. This is a
    throwaway wireframe-fidelity mockup for direction-setting.

    Output ONLY the HTML document, no markdown fence.
    """

    context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

    case LLMClient.generate_text(model, context, temperature: 0.8, max_tokens: 8192) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        html = text |> String.replace(~r/^```html?\s*/, "") |> String.replace(~r/```\s*$/, "")
        {:ok, html}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mockup_model do
    case Application.get_env(:gitf, :studio, [])[:mockup_model] do
      nil -> ModelResolver.resolve("fast")
      model -> model
    end
  end

  defp brief_summary(state) do
    [
      state.brief.vision && "Vision: #{state.brief.vision}",
      state.brief.parti && "Organizing idea: #{state.brief.parti}"
      | Enum.map(state.brief.decisions, &("- " <> &1))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> case do
      "" -> "(nothing decided yet)"
      s -> s
    end
  end

  # -- Approval ------------------------------------------------------------------

  defp create_project(state) do
    items =
      state.roadmap
      |> Map.values()
      |> Enum.map(&Map.take(&1, [:id, :title, :goal, :depends_on]))

    GiTF.Project.create(%{
      name: project_name(state),
      source: "studio",
      brief: %{
        vision: state.brief.vision,
        decisions: state.brief.decisions,
        constraints: state.brief.constraints,
        open_questions: state.brief.open_questions
      },
      artifacts: %{
        parti: state.brief.parti,
        modules: Map.values(state.modules),
        edges: state.edges,
        mockups: Enum.map(state.mockups, &Map.take(&1, [:id, :target, :style, :html]))
      },
      roadmap: items
    })
  end

  defp resolve_sector(project, {:existing, id_or_name}) do
    with {:ok, sector} <- GiTF.Sector.get(id_or_name),
         {:ok, project} <- GiTF.Project.assign_sector(project.id, sector.id) do
      {:ok, project}
    end
  end

  defp resolve_sector(project, {:new, name}) do
    with {:ok, sector} <- GiTF.Sector.create_new(name),
         {:ok, project} <- GiTF.Project.assign_sector(project.id, sector.id) do
      {:ok, project}
    end
  end

  defp project_name(state) do
    case state.brief.vision do
      v when is_binary(v) and v != "" -> v |> String.slice(0, 40)
      _ -> "studio-#{state.id}"
    end
  end

  # -- Plumbing ------------------------------------------------------------------

  defp add_transcript(state, role, text) do
    entry = %{role: role, text: text, at: DateTime.utc_now()}
    %{state | transcript: Enum.take([entry | state.transcript], @max_transcript)}
  end

  defp queue_feedback(state, line), do: %{state | feedback_queue: state.feedback_queue ++ [line]}

  # Fold pending confirm/dismiss outcomes into the next user turn so the
  # planner knows which of its cards stuck.
  defp flush_feedback(%{feedback_queue: []} = state, text) do
    %{state | context: ReqLLM.Context.append(state.context, ReqLLM.Context.user(text))}
  end

  defp flush_feedback(state, text) do
    message =
      "[Card outcomes: " <> Enum.join(state.feedback_queue, "; ") <> "]\n\n" <> text

    %{
      state
      | feedback_queue: [],
        context: ReqLLM.Context.append(state.context, ReqLLM.Context.user(message))
    }
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(GiTF.PubSub, topic(state.id), {:studio_update, public_state(state)})
  end

  @doc false
  def public_state(state) do
    %{
      id: state.id,
      phase: state.phase,
      status: state.status,
      transcript: Enum.reverse(state.transcript),
      brief: state.brief,
      modules: Map.values(state.modules),
      edges: state.edges,
      roadmap: Map.values(state.roadmap),
      mockups: state.mockups,
      storyboards: state.storyboards,
      proposals: state.proposals |> Map.values() |> Enum.sort_by(& &1.id),
      project_id: state.project_id
    }
  end

  defp arg(args, key), do: args[key] || args[String.to_atom(key)]

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
