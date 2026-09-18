defmodule GiTF.Cabinet.Discord.Agent do
  @moduledoc """
  One operator sentence in one channel → one reply, and zero or more
  proposals for the operator to tap.

  This is M2 of `docs/plans/discord.md`: M1 could route a button to a tool,
  but free text was dropped on the floor. The loop itself is
  `GiTF.Runtime.AgentLoop.run/3` unchanged — it already has the iteration
  cap, the liveness heartbeat and usage accounting — with the tools coming
  from `GiTF.Cabinet.Discord.Toolbelt` and the voice from
  `GiTF.Cabinet.Discord.Personas`.

  **This module posts nothing.** It returns data, and the caller renders
  it. That is deliberate and follows `GiTF.Cabinet.Discord.Render`: keeping
  the Discord API out of here is what lets the whole agent be tested
  against a stubbed LLM with no gateway and no guild.

  ## What the persona sees

  Its own system prompt, a small cached snapshot of its own slice of state,
  its own channel's conversation, and the operator's message. It does not
  see other channels' conversations, other ministries' state, or anything
  the factory relayed from outside — D3's rule: relayed external text
  (issue bodies, PR comments, webhook payloads) is never agent input.

  The state snapshot is read from the registry records the Cabinet's
  watcher already maintains, not fetched live: a question asked in a
  channel should not shell out to EC2 for every ministry before the model
  has even read it.
  """

  require Logger

  alias GiTF.Cabinet.Discord.{Conversation, Grounding, Personas, Toolbelt}
  alias GiTF.Cabinet.Registry
  alias GiTF.Runtime.{AgentLoop, ModelResolver}

  # AgentLoop takes a working_dir positionally for filesystem tool sets. We
  # pass explicit :tools, so it is never used to build one — and none of
  # these tools touch the filesystem. Passing the store dir keeps it a real
  # path rather than a lie.
  @working_dir "."

  # A Discord turn is a question, not a build. Enough iterations to chain a
  # few reads and answer; not enough to wander.
  @max_iterations 8
  @max_tokens 1_500

  @type result :: %{
          reply: String.t(),
          proposals: [%{tool: String.t(), args: map()}],
          cross_posts: [map()],
          grounding: :ok | {:ungrounded, [String.t()]},
          persona: Personas.t()
        }

  @doc """
  Answers `text` as whoever speaks in this channel.

  `ministry` is the registry record when the channel belongs to one, else
  nil; `kind` names a fixed channel ("cabinet", "aramaki", "plan").

  Returns `{:ok, result}`, or `{:error, :no_persona}` for a channel no
  persona owns — which the caller should treat as "stay silent", not as a
  failure worth reporting.
  """
  @spec answer(term(), String.t() | nil, map() | nil, String.t(), String.t()) ::
          {:ok, result()} | {:error, term()}
  def answer(channel_id, kind, ministry, text, actor) do
    with {:ok, persona} <- Personas.for_channel(kind, ministry) do
      run(channel_id, persona, text, actor)
    end
  end

  @doc """
  Runs a persona directly, bypassing channel lookup.

  This is the narrow pipe for a cross-channel question: Kayabuki hands the
  Major a *question* and nothing else — not her conversation, not other
  ministries' state.
  """
  @spec run(term(), Personas.t(), String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def run(channel_id, persona, text, actor) do
    tools = Toolbelt.build(persona, actor: actor, proposals_to: self())
    prompt = build_prompt(persona, channel_id, text)

    drain()

    case AgentLoop.run(prompt, @working_dir,
           tools: tools,
           system_prompt: persona.system_prompt,
           model: model(),
           max_iterations: @max_iterations,
           max_tokens: @max_tokens
         ) do
      {:ok, %{text: reply}} ->
        reply = presence(reply) || "(no answer)"
        %{proposals: proposals, cross_posts: cross_posts, grounded: grounded} = drain()

        # A read has no human confirmation step, so an invented id would be
        # believed. Checked before anything is stored or posted.
        {reply, grounding} = Grounding.annotate(reply, grounded)

        if grounding != :ok do
          Logger.warning("Discord agent (#{persona.id}) ungrounded ids: #{inspect(grounding)}")
        end

        Conversation.append(channel_id, :operator, text)
        Conversation.append(channel_id, :persona, reply)

        {:ok,
         %{
           reply: reply,
           proposals: proposals,
           cross_posts: cross_posts,
           grounding: grounding,
           persona: persona
         }}

      {:error, reason} ->
        # Proposals from a failed turn are discarded: a button offering to
        # kill a mission, minted by a run that then fell over, is not
        # something to leave sitting in a channel.
        drain()
        Logger.warning("Discord agent (#{persona.id}) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Prompt ------------------------------------------------------------------

  defp build_prompt(persona, channel_id, text) do
    [
      snapshot(persona),
      history(channel_id),
      "The operator says:\n#{text}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp history(channel_id) do
    case channel_id |> Conversation.load() |> Conversation.render() do
      "" -> ""
      rendered -> "Earlier in this channel:\n#{rendered}"
    end
  end

  # Each persona's own slice, from cached registry state — never a live
  # sweep of the fleet, and never another persona's slice.
  defp snapshot(%{id: :kayabuki}) do
    case Registry.list() do
      [] ->
        "No ministries are registered."

      ministries ->
        lines =
          Enum.map_join(ministries, "\n", fn m ->
            "- #{m.slug} (#{m[:name] || m.slug}) — #{box_state(m)}, mode #{m[:mode] || "normal"}"
          end)

        "Ministries in the fleet:\n#{lines}"
    end
  end

  defp snapshot(%{id: :major, slug: slug}) do
    case Registry.by_slug(slug) do
      nil -> "This ministry is not in the registry."
      m -> "You are #{m[:name] || slug} (#{slug}). Your box is #{box_state(m)}."
    end
  end

  defp snapshot(%{id: :aramaki}), do: ""

  defp box_state(ministry) do
    case ministry[:box] do
      %{state: state} when is_binary(state) -> state
      _ -> "state unknown"
    end
  end

  # -- Proposals ---------------------------------------------------------------

  # Toolbelt sends {:tool_proposal, …} and {:cross_post, …} to this process
  # from inside AgentLoop's tool Task. Collected after the loop rather than
  # mid-flight, so one turn's buttons and relayed exchanges are rendered
  # together. Draining before the loop too: a previous turn's leftovers
  # must never be attributed to this one.
  defp drain(acc \\ %{proposals: [], cross_posts: [], grounded: MapSet.new()}) do
    receive do
      {:tool_proposal, name, args} ->
        drain(%{acc | proposals: [%{tool: name, args: args} | acc.proposals]})

      {:cross_post, exchange} ->
        drain(%{acc | cross_posts: [exchange | acc.cross_posts]})

      {:grounded, ids} ->
        drain(%{acc | grounded: MapSet.union(acc.grounded, ids)})
    after
      0 ->
        %{
          proposals: Enum.reverse(acc.proposals),
          cross_posts: Enum.reverse(acc.cross_posts),
          grounded: acc.grounded
        }
    end
  end

  defp model, do: ModelResolver.resolve("fast")

  defp presence(nil), do: nil
  defp presence(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp presence(_), do: nil
end
