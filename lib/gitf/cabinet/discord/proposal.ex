defmodule GiTF.Cabinet.Discord.Proposal do
  @moduledoc """
  A write an agent wants, parked until the operator taps it.

  M1's buttons encode the whole act in the `custom_id`
  (`<action>:<slug>:<entity_id>`), which works because an alert already
  knows its entity. An agent's proposal does not fit that: `custom_id` is
  capped at 100 characters and `create_mission` carries a goal sentence.
  So the proposal is stored and the button carries only its id —
  `propose:<id>` — which keeps every proposable tool the same size on the
  wire, whatever its arguments.

  This is also the security boundary for agent-initiated writes. The
  stored record holds the tool, its arguments, the ministry and the actor
  as they were when proposed. Tapping executes *that*, not whatever the
  conversation has since become — and a proposal can only be spent once,
  so a button left in the scrollback is not a re-runnable action.
  """

  alias GiTF.Archive

  @collection :discord_proposals
  @keep 200

  @type t :: %{
          id: String.t(),
          tool: String.t(),
          args: map(),
          slug: String.t() | nil,
          actor: String.t(),
          channel_id: String.t(),
          status: String.t(),
          at: DateTime.t()
        }

  @doc "Parks a proposal and returns it with its id."
  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(%{tool: tool, args: args} = attrs) do
    result =
      Archive.insert(@collection, %{
        tool: tool,
        args: args || %{},
        slug: attrs[:slug],
        actor: attrs[:actor] || "discord:unknown",
        channel_id: to_string(attrs[:channel_id] || ""),
        status: "open",
        at: DateTime.utc_now()
      })

    with {:ok, _} <- result,
         do:
           (
             prune()
             result
           )
  end

  @doc "Fetches a proposal by id."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Archive.get(@collection, id)

  @doc """
  Marks a proposal spent, refusing a second tap.

  Returns `{:ok, proposal}` the first time and `{:error, :already_spent}`
  after — the check and the write are one `Archive.update/3`, so two taps
  racing cannot both win.
  """
  @spec spend(String.t()) :: {:ok, t()} | {:error, :already_spent | :not_found}
  def spend(id) do
    case Archive.update(@collection, id, fn proposal ->
           if Map.get(proposal, :status) == "open" do
             {:ok, Map.put(proposal, :status, "spent")}
           else
             {:error, :already_spent}
           end
         end) do
      {:ok, proposal} -> {:ok, proposal}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Hands a spent proposal back after the act itself failed.

  `spend/1` runs before the tool so a double-tap cannot execute twice, but
  that would also burn the button on a box that happened to be
  unreachable. Reopening on a definite failure keeps the guarantee where
  it matters — at most one execution *in flight* — while letting the
  operator tap again once the cause is fixed.
  """
  @spec reopen(String.t()) :: :ok
  def reopen(id) do
    Archive.update(@collection, id, fn proposal -> {:ok, Map.put(proposal, :status, "open")} end)
    :ok
  end

  @doc """
  The button a proposal renders as: `{label, style}`.

  A tool with no entry here is one the operator has no button for; the
  agent may still describe it in prose, but it cannot be tapped into
  existence.
  """
  @spec button(String.t()) :: {String.t(), atom()} | nil
  def button("answer_question"), do: {"Answer", :primary}
  def button("reject_question"), do: {"Reject all", :secondary}
  def button("approve_mission"), do: {"Approve", :success}
  def button("reject_mission"), do: {"Reject", :danger}
  def button("kill_mission"), do: {"Kill", :danger}
  def button("start_mission"), do: {"Start", :success}
  def button("resume_mission"), do: {"Resume", :primary}
  def button("close_mission"), do: {"Close", :secondary}
  def button("create_mission"), do: {"Create mission", :success}
  def button("approve_project"), do: {"Approve project", :success}
  def button("pause_project"), do: {"Pause project", :secondary}
  def button("resume_project"), do: {"Resume project", :primary}
  def button("update_project_roadmap"), do: {"Update roadmap", :primary}
  def button("set_config"), do: {"Apply change", :primary}
  def button("start_inbox_entry"), do: {"Start", :success}
  def button("dismiss_inbox_entry"), do: {"Drop", :secondary}
  def button(_), do: nil

  @doc "Open proposals, newest first — for diagnostics."
  def list(limit \\ 30) do
    @collection
    |> Archive.all()
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp prune do
    all = Archive.all(@collection)

    if length(all) > @keep do
      all
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
      |> Enum.drop(@keep)
      |> Enum.each(&Archive.delete(@collection, &1.id))
    end

    :ok
  end
end
