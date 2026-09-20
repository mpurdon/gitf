defmodule GiTF.Cabinet.Discord.Actions do
  @moduledoc """
  A button tap or menu pick → exactly one factory operation.

  `custom_id`s are minted by `GiTF.Cabinet.Discord.Render` and parsed here;
  each maps to one MCP tool on the ministry's factory (via
  `GiTF.Cabinet.Proxy`, waking the box if it sleeps — a tap on a sleep
  warning after the box already slept wakes it and applies the hold) or to
  one local Cabinet act (inbox start/drop, wake). No model is in the loop:
  the tap IS the confirmation the MCP's `confirm: true` contract demands,
  and the actor recorded on the factory is `discord:<username>`.

  Everything a Discord user can do from here is something the same person
  can do from the Catwalk today; nothing new is decided in Discord.
  """

  require Logger

  alias GiTF.Cabinet.Discord.Proposal
  alias GiTF.Cabinet.{Fleet, Gate, Proxy, Registry}

  @type parsed ::
          {:answer, slug :: String.t(), inquiry_id :: String.t(), answer :: term() | nil}
          | {:reject_all, String.t(), String.t()}
          | {:approve, String.t(), String.t()}
          | {:reject, String.t(), String.t()}
          | {:resume, String.t(), String.t()}
          | {:hold, String.t(), pos_integer()}
          | {:sleep, String.t()}
          | {:wake, String.t()}
          | {:inbox_start, String.t()}
          | {:inbox_drop, String.t()}
          | {:proposal, String.t()}

  @doc "Parses a custom_id (and the select values, if any) back into an action."
  @spec parse(String.t(), [String.t()]) :: {:ok, parsed} | {:error, :unknown_action}
  def parse(custom_id, values \\ []) do
    case String.split(custom_id, ":") do
      ["answer", slug, id] -> {:ok, {:answer, slug, id, List.first(values)}}
      ["answer", slug, id, "true"] -> {:ok, {:answer, slug, id, true}}
      ["answer", slug, id, "false"] -> {:ok, {:answer, slug, id, false}}
      ["reject_all", slug, id] -> {:ok, {:reject_all, slug, id}}
      ["approve", slug, id] -> {:ok, {:approve, slug, id}}
      ["reject", slug, id] -> {:ok, {:reject, slug, id}}
      ["resume", slug, id] -> {:ok, {:resume, slug, id}}
      ["hold", slug, minutes] -> parse_hold(slug, minutes)
      ["sleep", slug] -> {:ok, {:sleep, slug}}
      ["wake", slug] -> {:ok, {:wake, slug}}
      ["propose", id] -> {:ok, {:proposal, id}}
      ["inbox_start", id] -> {:ok, {:inbox_start, id}}
      ["inbox_drop", id] -> {:ok, {:inbox_drop, id}}
      _ -> {:error, :unknown_action}
    end
  end

  defp parse_hold(slug, minutes) do
    case Integer.parse(minutes) do
      {n, ""} when n > 0 -> {:ok, {:hold, slug, n}}
      _ -> {:error, :unknown_action}
    end
  end

  @doc """
  How the message should read once this action has succeeded.

  Returns a keyword list for `GiTF.Cabinet.Discord.Render.settled/3` —
  `:title`, `:description`, or neither.

  Only the acts that make the original wording *false* answer here. A hold
  or a sleep contradicts a heading that announces an imminent power-off and a
  body that names the time; leaving those in place produced the message this
  exists to prevent — "Sleeping in ~0 min", over a power-off time, under a
  footer saying the box had just been kept awake for four hours.

  An approval is the opposite case: its body is the mission goal, which is
  exactly what a reader scrolling back wants, and which approving does not
  make untrue. Those return `[]` and only their footer changes.
  """
  @spec resolved(parsed) :: keyword()
  def resolved({:hold, _slug, minutes}) do
    [
      title: "Staying awake",
      description: "Awake for another #{duration(minutes)}. The idle timer starts again after."
    ]
  end

  def resolved({:sleep, _slug}),
    do: [title: "Asleep", description: "Powered off. Waking it takes about a minute."]

  def resolved({:wake, _slug}),
    do: [title: "Awake", description: "Powered on and accepting work."]

  # Everything else keeps its body: the question, the goal, the failure
  # reason. Those are the record of what was decided, and the footer already
  # says who decided it.
  def resolved(_action), do: []

  defp duration(minutes) when minutes < 60, do: "#{minutes} minutes"
  defp duration(60), do: "an hour"

  defp duration(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {h, 0} -> "#{h} hours"
      {h, m} -> "#{h}h #{m}m"
    end
  end

  @doc """
  Performs a parsed action as `actor` (`"discord:<username>"`).

  Returns `{:ok, outcome_line}` — the sentence written under the message
  ("answered by @matt: option b · 21:04") — or `{:error, reason}`.
  """
  @spec perform(parsed, String.t()) :: {:ok, String.t()} | {:error, term()}
  def perform(action, actor) do
    who = String.replace_prefix(actor, "discord:", "@")

    case action do
      {:answer, _slug, _id, nil} ->
        {:error, "pick an option first"}

      {:answer, slug, id, answer} ->
        tool(slug, "answer_question", %{"id" => id, "answer" => answer}, actor)
        |> outcome("answered by #{who}: #{answer}")

      {:reject_all, slug, id} ->
        tool(
          slug,
          "reject_question",
          %{"id" => id, "direction" => "rejected from Discord by #{who}"},
          actor
        )
        |> outcome("all options rejected by #{who} — proposing again")

      {:approve, slug, id} ->
        tool(slug, "approve_mission", %{"id" => id}, actor)
        |> outcome("approved by #{who}")

      {:reject, slug, id} ->
        tool(
          slug,
          "reject_mission",
          %{"id" => id, "reason" => "rejected from Discord by #{who}"},
          actor
        )
        |> outcome("rejected by #{who}")

      {:resume, slug, id} ->
        tool(slug, "resume_mission", %{"id" => id}, actor)
        |> outcome("resumed by #{who}")

      {:hold, slug, minutes} ->
        tool(
          slug,
          "idle_stop_override",
          %{"hold_minutes" => minutes, "reason" => "held from Discord by #{who}"},
          actor
        )
        |> outcome("kept awake #{minutes} min by #{who}")

      {:sleep, slug} ->
        with %{} = ministry <- Registry.by_slug(slug) || {:error, :unknown_ministry},
             :ok <- Fleet.stop(ministry) do
          GiTF.Cabinet.Activity.record(actor, "stop", slug, "ok")
          {:ok, "put to sleep by #{who}"}
        end

      {:wake, slug} ->
        with %{} = ministry <- Registry.by_slug(slug) || {:error, :unknown_ministry},
             :ok <- Fleet.wake(ministry) do
          GiTF.Cabinet.Activity.record(actor, "wake", slug, "ok")
          {:ok, "woken by #{who}"}
        end

      # An agent's proposal: the tool and its arguments were parked when
      # proposed, so the tap performs what was offered, not what the
      # conversation has since drifted to. Spent first — a button in the
      # scrollback must not be re-runnable.
      {:proposal, id} ->
        case Proposal.spend(id) do
          {:ok, %{tool: name, args: args, slug: slug}} ->
            case perform_proposed(name, args, slug, actor, who) do
              {:ok, _} = ok ->
                ok

              {:error, _} = err ->
                # The act failed, so the offer stands: give the button back
                # rather than stranding the operator with a dead proposal.
                Proposal.reopen(id)
                err
            end

          {:error, :already_spent} ->
            {:error, "already done"}

          {:error, :not_found} ->
            {:error, "that proposal has expired"}
        end

      {:inbox_start, id} ->
        with :ok <- Gate.start_queued(id) do
          GiTF.Cabinet.Activity.record(actor, "start_queued", id, "ok", ministry_of(id))
          {:ok, "started by #{who}"}
        end

      {:inbox_drop, id} ->
        with :ok <- Gate.dismiss_queued(id) do
          GiTF.Cabinet.Activity.record(actor, "dismiss_queued", id, "ok", ministry_of(id))
          {:ok, "dropped by #{who}"}
        end
    end
  end

  # A proposed write runs exactly where it was proposed: a ministry tool
  # on that ministry, a Cabinet tool here. The slug comes off the stored
  # record, never off the tap.
  defp perform_proposed(name, args, slug, actor, who) when is_binary(slug) do
    slug |> tool(name, args, actor) |> outcome("#{label(name)} by #{who}")
  end

  # Config lives on the box the change is for: a ministry persona's proposal
  # carries its slug and is proxied there; Kayabuki's has none and applies to
  # the Cabinet itself.
  defp perform_proposed("set_config", args, nil, actor, who) do
    case GiTF.MCPServer.Handlers.call("set_config", Map.put(args, "confirm", true), actor: actor) do
      {:ok, _} ->
        GiTF.Cabinet.Activity.record(actor, "set_config", args["key"] || "", "ok")
        {:ok, "#{args["key"]} changed by #{who}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_proposed("start_inbox_entry", args, _slug, actor, _who) do
    perform({:inbox_start, args["id"]}, actor)
  end

  defp perform_proposed("dismiss_inbox_entry", args, _slug, actor, _who) do
    perform({:inbox_drop, args["id"]}, actor)
  end

  defp perform_proposed(name, _args, _slug, _actor, _who) do
    {:error, "#{name} cannot be performed from the Cabinet"}
  end

  defp label("answer_question"), do: "answered"
  defp label("reject_question"), do: "all options rejected"
  defp label("approve_mission"), do: "approved"
  defp label("reject_mission"), do: "rejected"
  defp label("kill_mission"), do: "killed"
  defp label("start_mission"), do: "started"
  defp label("resume_mission"), do: "resumed"
  defp label("close_mission"), do: "closed"
  defp label("create_mission"), do: "mission created"
  defp label("approve_project"), do: "project approved"
  defp label("pause_project"), do: "project paused"
  defp label("resume_project"), do: "project resumed"
  defp label("update_project_roadmap"), do: "roadmap updated"
  defp label(name), do: "#{name} run"

  # An inbox id says nothing about which ministry it was headed for; the entry
  # does, and the Console groups by it.
  defp ministry_of(id) do
    case Enum.find(Gate.inbox(), &(&1.id == id)) do
      %{ministry_slug: slug} -> slug
      _ -> nil
    end
  end

  # Every factory-side act is one MCP call on that ministry, confirmed by
  # construction (the tap) and attributed to the person. `wake: true`: a
  # decision taken after the box slept is still a decision.
  defp tool(slug, name, args, actor) do
    args = Map.put(args, "confirm", true)

    case Proxy.call(slug, name, args, wake: true, actor: actor) do
      {:ok, text} ->
        if String.starts_with?(text, "Error:") do
          {:error, String.replace_prefix(text, "Error: ", "")}
        else
          GiTF.Cabinet.Activity.record(actor, name, "#{slug} #{args["id"] || ""}", "ok", slug)
          :ok
        end

      {:error, reason} ->
        GiTF.Cabinet.Activity.record(actor, name, slug, "failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp outcome(:ok, line), do: {:ok, line}
  defp outcome({:error, _} = err, _line), do: err
end
