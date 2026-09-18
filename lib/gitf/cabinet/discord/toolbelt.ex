defmodule GiTF.Cabinet.Discord.Toolbelt do
  @moduledoc """
  A persona's tools, as `ReqLLM.Tool` structs the agent loop can call.

  `GiTF.MCPServer.Tools.all/0` describes 85 tools in MCP's `inputSchema`
  JSON Schema; nothing converted those into something an in-process LLM
  loop could use. This is that adapter, and it is where three guarantees
  are actually enforced rather than requested:

  ## The allow-list is structural

  Only names in `persona.tools` are built. A tool that is not built cannot
  be called, however the conversation goes — as opposed to a prompt asking
  the model not to.

  ## The ministry is bound, never an argument

  For a ministry persona the slug is captured in each callback's closure.
  It is not in the tool's parameter schema, so there is no argument the
  model can set to reach a different Section. The Major in `#home-affairs`
  cannot read `trajector` because no code path exists, not because it was
  told not to.

  ## The actor survives the process hop

  `Handlers.call/3` records who acted in the *process dictionary*
  (`handlers.ex:36-48`). `GiTF.Runtime.AgentLoop` executes tools inside
  `Task.async` (`agent_loop.ex:243`), a different process from the one
  that started the loop — so an actor set before `AgentLoop.run/3` would be
  invisible here and every Discord-driven act would file itself as
  `mcp_operator`. Each callback therefore closes over the actor and passes
  it explicitly, which works whichever process runs it.

  Writes that change mission or project state are not performed here at
  all: `persona.confirm` names them, and calling one records a *proposal*
  and tells the model to carry on. The operator's tap performs it through
  the M1 path (`GiTF.Cabinet.Discord.Actions`), so the confirmed write and
  the button write are the same code.
  """

  require Logger

  alias GiTF.Cabinet.Discord.{Grounding, Personas}
  alias GiTF.Cabinet.Proxy
  alias GiTF.MCPServer.{Handlers, Tools}

  @doc """
  Builds the tool list for `persona`.

  Options:

    * `:actor` — required; `"discord:<username>"`. Closed over by every
      callback.
    * `:proposals_to` — pid that receives `{:tool_proposal, name, args}`
      for each confirm-tier call. Defaults to `self()` at build time,
      which is the agent process.
  """
  @spec build(Personas.t(), keyword()) :: [ReqLLM.Tool.t()]
  def build(persona, opts) do
    actor = Keyword.fetch!(opts, :actor)
    collector = Keyword.get(opts, :proposals_to, self())
    by_name = Map.new(Tools.all(), &{&1.name, &1})

    mcp =
      persona.tools
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        case Map.fetch(by_name, name) do
          {:ok, definition} ->
            [to_req_llm_tool(definition, persona, actor, collector)]

          :error ->
            # A persona naming a tool that no longer exists is a bug in the
            # allow-list, not a reason to refuse the whole conversation.
            Logger.warning("Discord toolbelt: #{persona.id} names unknown tool #{name}")
            []
        end
      end)

    mcp ++ local(persona, actor, collector)
  end

  # Tools that are not MCP tools at all — they act on the Cabinet's own
  # Discord surface. Only Kayabuki has one, and only one: she presides over
  # ministries, so she is the only persona who may address another.
  defp local(%{local_tools: names}, actor, collector) do
    Enum.flat_map(names, &local_tool(&1, actor, collector))
  end

  defp local(_persona, _actor, _collector), do: []

  defp local_tool("ask_ministry", actor, collector) do
    [
      ReqLLM.Tool.new!(
        name: "ask_ministry",
        description:
          "Put a question to a ministry's Major, in its own channel, and read the answer. " <>
            "Use this whenever the operator asks about a specific ministry's missions, ops or " <>
            "questions — you cannot see a Section's internals yourself. Name the ministry the " <>
            "way the operator did; prose like \"home affairs\" resolves fine.",
        parameter_schema: %{
          type: "object",
          properties: %{
            ministry: %{type: "string", description: "The ministry, by slug or name."},
            question: %{type: "string", description: "The question, in plain words."}
          },
          required: ["ministry", "question"]
        },
        callback: fn args -> ask_ministry(stringify(args), actor, collector) end
      )
    ]
  end

  defp local_tool(name, _actor, _collector) do
    Logger.warning("Discord toolbelt: unknown local tool #{name}")
    []
  end

  # The narrow pipe between personas. Exactly two things cross: the
  # question and who is asking. Not Kayabuki's conversation, not any other
  # ministry's state — and the Major she reaches has no `ask_ministry` of
  # its own, so one hop is the most that can ever happen.
  defp ask_ministry(%{"ministry" => prose, "question" => question}, actor, collector)
       when is_binary(prose) and is_binary(question) do
    case GiTF.Cabinet.Registry.resolve(prose) do
      {:ok, ministry} ->
        relay(ministry, question, actor, collector)

      {:ambiguous, candidates} ->
        names = Enum.map_join(candidates, ", ", & &1.slug)
        {:ok, "That could be any of: #{names}. Ask the operator which one they meant."}

      {:error, :no_match} ->
        known = GiTF.Cabinet.Registry.list() |> Enum.map_join(", ", & &1.slug)
        {:ok, "There is no ministry matching #{inspect(prose)}. Registered: #{known}."}
    end
  end

  defp ask_ministry(_args, _actor, _collector),
    do: {:ok, "ask_ministry needs both a ministry and a question."}

  defp relay(ministry, question, actor, collector) do
    persona = Personas.major(ministry)
    channel_id = ministry[:discord_channel_id]

    case GiTF.Cabinet.Discord.Agent.run(channel_id, persona, question, actor) do
      {:ok, result} ->
        # The exchange is posted by the caller, not here: this module stays
        # free of the Discord API so it remains testable without a gateway.
        send(
          collector,
          {:cross_post,
           %{
             slug: ministry.slug,
             channel_id: channel_id,
             question: question,
             persona: persona,
             reply: result.reply,
             proposals: result.proposals
           }}
        )

        {:ok, "#{ministry.slug} says: #{result.reply}"}

      {:error, reason} ->
        {:ok, "#{ministry.slug} could not be reached (#{inspect(reason)})."}
    end
  end

  defp to_req_llm_tool(definition, persona, actor, collector) do
    name = definition.name

    opts = [
      name: name,
      description: definition.description,
      callback: fn args -> dispatch(name, args, persona, actor, collector) end
    ]

    # ReqLLM.Tool accepts a JSON Schema map directly (req_llm tool.ex:135),
    # so MCP's inputSchema goes through untouched. A schema with no
    # properties is dropped — an empty one compiles to nothing useful.
    opts =
      case definition[:inputSchema] do
        %{properties: props} = schema when props != %{} ->
          Keyword.put(opts, :parameter_schema, schema)

        _ ->
          opts
      end

    ReqLLM.Tool.new!(opts)
  end

  # Confirm tier: record and return. The model is told to keep going rather
  # than wait, exactly as the studio's proposal cards do
  # (`studio/session.ex:336-358`) — a model blocked on a human tap burns
  # its iteration budget doing nothing.
  defp dispatch(name, args, persona, actor, collector) do
    if Personas.confirms?(persona, name) do
      # Stringified here too, not just on the perform path: the agent reads
      # these args to mint the button's custom_id, and a key that is
      # sometimes an atom and sometimes a string breaks that lookup.
      send(collector, {:tool_proposal, name, stringify(args)})

      {:ok,
       "Proposed to the operator as a button; they will tap to confirm. " <>
         "Do not wait for it and do not report it as done — say what you " <>
         "proposed and why."}
    else
      perform(name, args, persona, actor, collector)
    end
  end

  defp perform(name, args, persona, actor, collector) do
    result =
      case persona do
        %{slug: nil} ->
          # Cabinet-local: the Cabinet's own registry, inbox and fleet.
          Handlers.call(name, stringify(args), actor: actor)

        %{slug: slug} when is_binary(slug) ->
          # A ministry persona. `slug` comes from the closure, never from
          # `args`. `wake: true` because the fleet sleeps by default and a
          # question asked of a sleeping box should answer, not fail.
          Proxy.call(slug, name, stringify(args), wake: true, actor: actor)
      end

    result = to_result(result)

    # Every id the factory just told us about is fair game for the reply.
    # Anything else in the reply was invented — see
    # `GiTF.Cabinet.Discord.Grounding`.
    with {:ok, text} <- result do
      send(collector, {:grounded, Grounding.ids(text)})
    end

    result
  end

  # The model produces string keys through JSON; MCP handlers pattern-match
  # on them. Atom keys can still arrive from a hand-built test call.
  defp stringify(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify(_), do: %{}

  # A tool that returns {:error, ...} aborts the loop in ReqLLM; a factory
  # error is information the model should see and work with, so failures
  # come back as :ok text. A wake timeout in particular is worth saying out
  # loud rather than swallowing.
  defp to_result({:ok, text}), do: {:ok, text}
  defp to_result({:error, reason}), do: {:ok, "Tool failed: #{describe(reason)}"}

  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp describe(reason), do: reason |> inspect() |> String.slice(0, 500)
end
