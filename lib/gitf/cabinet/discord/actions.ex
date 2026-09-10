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

      {:inbox_start, id} ->
        with :ok <- Gate.start_queued(id) do
          GiTF.Cabinet.Activity.record(actor, "start_queued", id, "ok")
          {:ok, "started by #{who}"}
        end

      {:inbox_drop, id} ->
        with :ok <- Gate.dismiss_queued(id) do
          GiTF.Cabinet.Activity.record(actor, "dismiss_queued", id, "ok")
          {:ok, "dropped by #{who}"}
        end
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
          GiTF.Cabinet.Activity.record(actor, name, "#{slug} #{args["id"] || ""}", "ok")
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
