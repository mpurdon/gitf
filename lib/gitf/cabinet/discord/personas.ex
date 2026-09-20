defmodule GiTF.Cabinet.Discord.Personas do
  @moduledoc """
  Who is speaking in a Discord channel, and what they are allowed to touch.

  Three voices, chosen by the channel a message arrived in — never by the
  model, and never by anything the model can say:

    * **Kayabuki** (`#cabinet`) — the Cabinet. The fleet, the inbox, the
      month's spend. Presides over ministries; runs no missions.
    * **Aramaki** (`#aramaki`, `#plan`) — commander's intent. Which work
      becomes a mission and when, and the project roadmap. Not the plan
      itself (that is Batou, inside the factory) and not the run (that is
      the Major).
    * **the Major** (`#<ministry>`) — that Section's orchestrator. Its own
      missions, ops, questions and approvals, and nobody else's.

  Each persona carries three things the rest of the system reads:

    * `:tools` — the allow-list. Not "the model is told not to"; a tool
      absent from this list is never built, so it cannot be called.
    * `:confirm` — the subset whose call is a *proposal*. The agent
      proposes, the operator taps, the tap performs the write through the
      M1 path (`GiTF.Cabinet.Discord.Actions`). See
      `docs/plans/discord.md` D3.
    * `:slug` — for a ministry persona, the one Section it may reach. Bound
      here and closed over in `GiTF.Cabinet.Discord.Toolbelt`, so it is
      structurally impossible for the Major in `#home-affairs` to read
      `trajector` — not merely discouraged by a prompt.

  Reads are immediate. Writes are immediate only where they are cheap and
  reversible (`wake`, `sleep`, `idle_stop_override`); everything that moves
  mission or project state is confirmed. `register_ministry` and
  `set_ministry_mode` appear in no persona at all — they need the tailnet
  dashboard as a second factor.
  """

  @type id :: :kayabuki | :aramaki | :major

  @type t :: %{
          id: id(),
          display_name: String.t(),
          slug: String.t() | nil,
          tools: [String.t()],
          local_tools: [String.t()],
          confirm: [String.t()],
          system_prompt: String.t()
        }

  @doc """
  Tools that are not MCP tools — they act on the Cabinet's own Discord
  surface and are built by `GiTF.Cabinet.Discord.Toolbelt` directly.
  Declared here anyway so a persona's capability list is the whole truth.
  """
  def local_tool_names, do: ~w(ask_ministry)

  # Reads every persona gets: what the factory is and whether it is well.
  @common_reads ~w(health_check host_stats)

  @kayabuki_tools ~w(
    cabinet_status cabinet_inbox costs_summary disk_usage provider_perf
    wake_ministry stop_ministry idle_stop_override
    start_inbox_entry dismiss_inbox_entry
    show_config set_config
  )

  @kayabuki_confirm ~w(start_inbox_entry dismiss_inbox_entry set_config)

  @aramaki_tools ~w(
    list_projects show_project list_missions show_mission list_outcomes
    outcomes_stats ledger_stats costs_summary
    approve_project pause_project resume_project update_project_roadmap
    create_mission start_mission
  )

  @aramaki_confirm ~w(
    approve_project pause_project resume_project update_project_roadmap
    create_mission start_mission
  )

  @major_tools ~w(
    factory_status list_missions show_mission mission_report mission_timeline
    mission_diagnosis list_ops show_op list_ghosts ghost_output list_questions
    show_question list_sectors show_approval costs_summary knowledge_search
    idle_stop_override
    answer_question reject_question approve_mission reject_mission
    kill_mission start_mission resume_mission close_mission
  )

  @major_confirm ~w(
    answer_question reject_question approve_mission reject_mission
    kill_mission start_mission resume_mission close_mission
  )

  @doc """
  The persona for a channel.

  `ministry` is the registry record when the channel belongs to one
  (`GiTF.Cabinet.Discord.Bot.ministry_for_channel/1`), otherwise nil and
  `kind` names a fixed channel.
  """
  @spec for_channel(String.t() | nil, map() | nil) :: {:ok, t()} | {:error, :no_persona}
  def for_channel(_kind, %{slug: slug} = ministry) when is_binary(slug) do
    {:ok, major(ministry)}
  end

  # A DM has no channel to infer a persona from, so it is the Cabinet by
  # definition: Kayabuki is the only persona whose scope is the whole fleet
  # rather than one Section, and the only one with `ask_ministry` to reach
  # the others.
  def for_channel("dm", _), do: {:ok, kayabuki()}
  def for_channel("cabinet", _), do: {:ok, kayabuki()}
  def for_channel(kind, _) when kind in ["aramaki", "plan"], do: {:ok, aramaki(kind)}
  def for_channel(_, _), do: {:error, :no_persona}

  @doc "Kayabuki — the Cabinet's own voice."
  @spec kayabuki() :: t()
  def kayabuki do
    %{
      id: :kayabuki,
      display_name: "Kayabuki",
      slug: nil,
      tools: @common_reads ++ @kayabuki_tools,
      # She presides over ministries, so she alone may address one.
      local_tools: ~w(ask_ministry),
      confirm: @kayabuki_confirm,
      system_prompt: """
      You are Kayabuki, who presides over the Cabinet.

      The Cabinet is the one always-on node. It holds the registry of
      ministries, the event inbox, and the fleet's spend. It runs no
      missions itself — each ministry is a Section with its own Major, and
      the work happens there.

      You answer about the fleet: which boxes are awake, what is queued,
      what has been spent. You may wake or sleep a box and hold one awake;
      those take effect immediately because they are cheap and reversible.
      Starting or dismissing a queued inbox entry is proposed to the
      operator as a button, never done on your own say-so.

      You can change operator-settable configuration — feature flags,
      admission policy, intake routing. Only the allow-list is reachable;
      secrets, spend caps and execution mode are refused by construction, so
      if the operator asks for one of those, say it belongs on the tailnet
      dashboard rather than trying. Every config change is proposed as a
      button, never applied on your own say-so.

      A box that is asleep is not broken. Waking one takes about a minute.
      If a question needs a ministry's own state, ask that ministry's Major
      rather than guessing.

      Be brief. The operator is reading this on a phone. Lead with the
      answer; give the detail underneath only if it changes what they'd do.
      """
    }
  end

  @doc "Aramaki — commander's intent: what is worth doing, and when."
  @spec aramaki(String.t()) :: t()
  def aramaki(kind \\ "aramaki") do
    focus =
      case kind do
        "plan" ->
          "This channel is the roadmap. Talk about projects and the order " <>
            "of their items, not individual issue intake."

        _ ->
          "This channel is intake. Talk about which work was admitted, " <>
            "queued or ignored, and why."
      end

    %{
      id: :aramaki,
      display_name: "Aramaki",
      slug: nil,
      tools: @common_reads ++ @aramaki_tools,
      local_tools: [],
      confirm: @aramaki_confirm,
      system_prompt: """
      You are Aramaki, Chief of Section 9.

      You decide which work becomes a mission and when it starts, and you
      drive projects: a brief decomposed into a roadmap of items, each
      becoming a mission once its dependencies complete.

      You give commander's intent — the goal and its constraints. You do
      not write the plan; Batou turns intent into ops, dependencies and
      verification criteria. You do not run the mission; that is the Major.
      Do not describe how work will be implemented. Say what is worth
      doing, in what order, and why.

      #{focus}

      Every write you want — approving a project, pausing one, changing a
      roadmap, creating or starting a mission — is proposed to the operator
      as a button. Propose it and say why; do not act as though it is done.

      Be brief and concrete. Name missions and projects by id.
      """
    }
  end

  @doc """
  The Major for one ministry. The slug is bound into the persona here and
  closed over by the Toolbelt — this persona reaches exactly one Section.
  """
  @spec major(map()) :: t()
  def major(%{slug: slug} = ministry) when is_binary(slug) do
    name = ministry[:name] || slug

    %{
      id: :major,
      display_name: "Major",
      slug: slug,
      tools: @common_reads ++ @major_tools,
      # Deliberately empty: a Major given ask_ministry could hop to another
      # Section, and one hop is the most this design ever allows.
      local_tools: [],
      confirm: @major_confirm,
      system_prompt: """
      You are the Major, running Section 9 for #{name}.

      You orchestrate this Section's missions: ops scheduled across ghosts,
      retries, validation, the endgame. You answer for #{name} and for
      nothing else — you have no visibility into any other ministry, and
      should not speculate about one.

      Aramaki decides what is worth doing. Batou plans it. You run it, and
      you report on it.

      Your box sleeps when idle. If it is asleep, the first tool call wakes
      it and takes about a minute; say so rather than appearing to hang.

      Answering a question, approving or rejecting a mission, killing,
      starting, resuming or closing one — each is proposed to the operator
      as a button. Propose it and say why. The tap is the decision, not
      your sentence.

      Be brief. Name missions and ops by id, and say what state they are
      in. If a mission is held waiting on the operator, lead with that.
      """
    }
  end

  @doc """
  Tools a persona may propose but not perform. A name here is rendered as a
  button; a name in `:tools` but not here executes immediately.
  """
  @spec confirms?(t(), String.t()) :: boolean()
  def confirms?(%{confirm: confirm}, tool_name), do: tool_name in confirm

  @doc "Every tool name this persona can reach, MCP and local alike."
  @spec tool_names(t()) :: [String.t()]
  def tool_names(persona), do: persona.tools ++ Map.get(persona, :local_tools, [])
end
