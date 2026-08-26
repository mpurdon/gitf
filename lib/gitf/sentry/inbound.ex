defmodule GiTF.Sentry.Inbound do
  @moduledoc """
  Maps an inbound Sentry webhook payload to a Factory mission.

  Sentry "Internal Integrations" fire `event_alert` / `issue_alert` /
  `issue.created` style payloads. The shape we care about:

      %{
        "action" => "created" | "triggered" | "resolved" | ...,
        "data" => %{
          "issue" => %{
            "id" => "...",
            "title" => "...",
            "shortId" => "PROJ-1",
            "permalink" => "https://sentry.io/...",
            "level" => "error",
            "culprit" => "...",
            "metadata" => %{"type" => "...", "value" => "..."},
            "project" => %{"slug" => "frontend-app"}
          }
          # event payloads carry "event" instead/in addition; we read both
        }
      }

  Sectors are resolved via `:sentry_project_to_sector` config (a map from
  Sentry project slug → sector id). When the project is unmapped the
  controller still returns 200 and we log+drop the event — webhook senders
  should not learn which projects we route.

  Per-sector dedup uses Sentry's own grouping: an `issue.id` is stable
  across event recurrences, so the first event for issue X creates one
  mission with `issue_ref = %{"source" => "sentry", "issue_id" => X, ...}`,
  and subsequent events for the same X within the same sector bump
  `mission.artifacts["sentry"]["occurrences"]` instead of creating a new
  mission.

  Only the configured trigger actions create missions. By default that's
  `["created", "triggered"]`; resolution events are ignored (the Factory's
  outcome tracker handles its own merge → revert detection).
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Missions

  @default_trigger_actions ~w(created triggered)

  @doc """
  Process a verified Sentry payload. Returns one of:

    * `{:ok, :created, mission}` — new mission was created
    * `{:ok, :deduped, mission}` — existing open mission updated
    * `{:ok, :ignored, reason}` — payload was valid but did not warrant a mission
    * `{:error, reason}` — payload was malformed

  The controller treats every non-`:error` result as 200 OK to avoid
  leaking which projects/issues are tracked.
  """
  @spec dispatch(map()) ::
          {:ok, :created, map()}
          | {:ok, :deduped, map()}
          | {:ok, :ignored, atom()}
          | {:error, term()}
  def dispatch(payload) when is_map(payload) do
    with {:ok, action} <- fetch_action(payload),
         :ok <- check_action_allowed(action),
         {:ok, issue} <- extract_issue(payload),
         {:ok, project_slug} <- extract_project_slug(issue),
         {:ok, sector_id} <- resolve_sector(project_slug) do
      handle_issue(issue, sector_id, action)
    else
      {:ignored, reason} -> {:ok, :ignored, reason}
      {:error, _} = err -> err
    end
  end

  def dispatch(_), do: {:error, :invalid_payload}

  # -- Pipeline steps --------------------------------------------------------

  defp fetch_action(%{"action" => a}) when is_binary(a), do: {:ok, a}
  defp fetch_action(_), do: {:error, :missing_action}

  defp check_action_allowed(action) do
    if action in trigger_actions(), do: :ok, else: {:ignored, :action_not_triggered}
  end

  defp extract_issue(%{"data" => %{"issue" => issue}}) when is_map(issue), do: {:ok, issue}

  defp extract_issue(%{"data" => %{"event" => %{"issue" => issue}}}) when is_map(issue),
    do: {:ok, issue}

  defp extract_issue(_), do: {:error, :missing_issue}

  defp extract_project_slug(%{"project" => %{"slug" => slug}}) when is_binary(slug),
    do: {:ok, slug}

  defp extract_project_slug(%{"project_slug" => slug}) when is_binary(slug), do: {:ok, slug}
  defp extract_project_slug(_), do: {:error, :missing_project}

  defp resolve_sector(slug) do
    case project_map()[slug] do
      sector_id when is_binary(sector_id) and sector_id != "" -> {:ok, sector_id}
      _ -> {:ignored, :project_not_mapped}
    end
  end

  defp handle_issue(issue, sector_id, action) do
    issue_id = to_string(issue["id"] || "")

    if issue_id == "" do
      {:error, :missing_issue_id}
    else
      case find_existing(sector_id, issue_id) do
        nil -> create_new(issue, sector_id, action)
        mission -> dedupe(mission, issue, action)
      end
    end
  end

  # -- Mission creation ------------------------------------------------------

  defp create_new(issue, sector_id, action) do
    title = issue["title"] || issue["shortId"] || "Sentry issue"
    short_id = issue["shortId"] || issue["id"]
    level = issue["level"] || "error"
    permalink = issue["permalink"] || ""
    culprit = issue["culprit"] || ""
    msg = get_in(issue, ["metadata", "value"]) || ""
    type = get_in(issue, ["metadata", "type"]) || ""

    goal =
      """
      Investigate Sentry #{level}: #{title}

      Short ID: #{short_id}
      Sentry: #{permalink}
      #{if culprit != "", do: "Culprit: #{culprit}\n", else: ""}#{if type != "", do: "Type: #{type}\n", else: ""}#{if msg != "", do: "Message: #{msg}\n", else: ""}
      Triggered by Sentry webhook (#{action}).
      """
      |> String.trim()

    name = "Sentry: #{String.slice(title, 0, 60)}"

    issue_ref = %{
      "source" => "sentry",
      "issue_id" => to_string(issue["id"]),
      "short_id" => short_id,
      "project" => get_in(issue, ["project", "slug"])
    }

    attrs = %{
      goal: goal,
      name: name,
      sector_id: sector_id,
      issue_ref: issue_ref
    }

    sentry_artifacts = %{
      "first_seen_action" => action,
      "occurrences" => 1,
      "permalink" => permalink,
      "level" => level
    }

    with {:ok, mission} <- Missions.create(attrs),
         {:ok, mission} <- attach_sentry_artifacts(mission, sentry_artifacts) do
      GiTF.Sentry.IssueIndex.put(sector_id, to_string(issue["id"]), mission.id)

      Logger.info(
        "Sentry webhook: created mission #{mission.id} for issue #{short_id} (sector=#{sector_id})"
      )

      emit_telemetry(:created, mission, sector_id)
      {:ok, :created, mission}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_sentry_artifacts(mission, sentry_artifacts) do
    Archive.update(:missions, mission.id, fn m ->
      artifacts = Map.put(m[:artifacts] || %{}, "sentry", sentry_artifacts)
      Map.put(m, :artifacts, artifacts)
    end)
  end

  defp dedupe(mission, _issue, action) do
    {:ok, updated} =
      Archive.update(:missions, mission.id, fn m ->
        sentry_artifacts =
          m
          |> Map.get(:artifacts, %{})
          |> Map.get("sentry", %{})

        bumped =
          sentry_artifacts
          |> Map.update("occurrences", 2, &(&1 + 1))
          |> Map.put("last_seen_action", action)
          |> Map.put("last_seen_at", DateTime.utc_now() |> DateTime.to_iso8601())

        artifacts = Map.put(m[:artifacts] || %{}, "sentry", bumped)
        Map.put(m, :artifacts, artifacts)
      end)

    Logger.info(
      "Sentry webhook: deduped to existing mission #{updated.id} (occurrences=#{get_in(updated, [:artifacts, "sentry", "occurrences"])})"
    )

    emit_telemetry(:deduped, updated, updated[:sector_id])
    {:ok, :deduped, updated}
  end

  # -- Lookup ---------------------------------------------------------------

  @doc """
  Returns the existing open mission for `{sector_id, sentry_issue_id}` if
  one exists, else nil. Exposed for tests.
  """
  @spec find_existing(String.t(), String.t()) :: map() | nil
  def find_existing(sector_id, issue_id) do
    issue_id = to_string(issue_id)

    case GiTF.Sentry.IssueIndex.get(sector_id, issue_id) do
      nil ->
        scan_for_existing(sector_id, issue_id)

      mission_id ->
        case Archive.get(:missions, mission_id) do
          nil ->
            GiTF.Sentry.IssueIndex.delete(sector_id, issue_id)
            scan_for_existing(sector_id, issue_id)

          %{status: status} when status in ["failed", "closed"] ->
            nil

          mission ->
            mission
        end
    end
  end

  defp scan_for_existing(sector_id, issue_id) do
    case Archive.filter(:missions, fn m ->
           m[:sector_id] == sector_id and
             match?(%{"source" => "sentry", "issue_id" => ^issue_id}, m[:issue_ref]) and
             m[:status] not in ["failed", "closed"]
         end)
         |> List.first() do
      nil ->
        nil

      mission ->
        GiTF.Sentry.IssueIndex.put(sector_id, issue_id, mission[:id])
        mission
    end
  end

  # -- Config ---------------------------------------------------------------

  defp trigger_actions do
    case Application.get_env(:gitf, :sentry_trigger_actions) do
      list when is_list(list) and list != [] -> Enum.map(list, &to_string/1)
      _ -> @default_trigger_actions
    end
  end

  defp project_map do
    Application.get_env(:gitf, :sentry_project_to_sector, %{}) || %{}
  end

  defp emit_telemetry(event, mission, sector_id) do
    GiTF.Telemetry.emit([:gitf, :sentry, :webhook], %{count: 1}, %{
      event: event,
      mission_id: mission[:id] || mission.id,
      sector_id: sector_id
    })
  rescue
    _ -> :ok
  end
end
