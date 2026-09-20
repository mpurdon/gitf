defmodule GiTF.Jira.Inbound do
  @moduledoc """
  Turns an inbound Jira issue webhook into a deduped, admission-gated
  **pending** mission — the same contract `GiTF.Aramaki.Intake` provides for
  GitHub issues.

  Jira fires `jira:issue_created` / `jira:issue_updated` with the shape:

      %{
        "webhookEvent" => "jira:issue_updated",
        "issue" => %{
          "key" => "PROJ-123",
          "fields" => %{
            "summary" => "...",
            "description" => "...",
            "labels" => ["gitf:build"],
            "issuetype" => %{"name" => "Bug"},
            "status" => %{"statusCategory" => %{"key" => "indeterminate"}},
            "reporter" => %{"accountId" => "..."},
            "project" => %{"key" => "PROJ"}
          }
        }
      }

  Sectors resolve through `:jira_project_to_sector` (Jira project key →
  sector id), mirroring Sentry's project map rather than GitHub's repo
  lookup — a Jira project has no `owner/repo` to match on. An unmapped
  project is logged and dropped, and the controller still answers 200:
  a webhook sender should not learn which projects are routed.

  Dedup is keyed by the issue key (`PROJ-123`), which is stable across
  edits and relabels, so re-labelling an already-ingested ticket updates
  rather than duplicates.

  This does NOT start the mission. It creates it pending with
  `source: "jira_issue"`, and `GiTF.Aramaki` admits it within the same
  concurrency ceiling every other intake channel shares.
  """

  require Logger

  alias GiTF.Aramaki.Policy
  alias GiTF.Archive
  alias GiTF.Missions

  @trigger_events ~w(jira:issue_created jira:issue_updated)

  @doc """
  Dispatches a Jira webhook payload. Returns one of:

    * `{:ok, :admitted, mission}` — new pending mission created
    * `{:ok, :deduped, mission}` — already ingested; refreshed in place
    * `{:ok, :ignored, reason}` — not labelled, closed, bot activity,
      unmapped project, or an event kind we do not act on
    * `{:error, reason}` — malformed payload
  """
  @spec dispatch(map()) ::
          {:ok, :admitted | :deduped, map()} | {:ok, :ignored, atom()} | {:error, term()}
  def dispatch(payload) when is_map(payload) do
    with {:ok, event} <- fetch_event(payload),
         :ok <- check_event_allowed(event),
         {:ok, issue} <- extract_issue(payload),
         {:ok, key} <- extract_key(issue),
         {:ok, project_key} <- extract_project_key(issue),
         {:ok, sector_id} <- resolve_sector(project_key) do
      handle_issue(issue, key, sector_id)
    else
      {:ignored, reason} -> {:ok, :ignored, reason}
      {:error, _} = err -> err
    end
  end

  def dispatch(_), do: {:error, :invalid_payload}

  # -- Pipeline steps ----------------------------------------------------------

  defp fetch_event(%{"webhookEvent" => e}) when is_binary(e), do: {:ok, e}
  defp fetch_event(_), do: {:error, :missing_event}

  defp check_event_allowed(event) do
    if event in @trigger_events, do: :ok, else: {:ignored, :event_not_triggered}
  end

  defp extract_issue(%{"issue" => issue}) when is_map(issue), do: {:ok, issue}
  defp extract_issue(_), do: {:error, :missing_issue}

  defp extract_key(%{"key" => key}) when is_binary(key) and key != "", do: {:ok, key}
  defp extract_key(_), do: {:error, :missing_issue_key}

  defp extract_project_key(issue) do
    case get_in(issue, ["fields", "project", "key"]) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_project}
    end
  end

  defp resolve_sector(project_key) do
    case project_map()[project_key] do
      sector_id when is_binary(sector_id) and sector_id != "" ->
        {:ok, sector_id}

      _ ->
        Logger.debug("Jira webhook: project #{project_key} not mapped to a sector")
        {:ignored, :project_not_mapped}
    end
  end

  defp handle_issue(issue, key, sector_id) do
    case find_existing(sector_id, key) do
      nil ->
        case Policy.admit_jira?(issue, bot_account: bot_account()) do
          {:admit, priority} -> create(issue, key, sector_id, priority)
          {:reject, reason} -> {:ok, :ignored, reason}
        end

      mission ->
        # Already ingested. Re-labelling or editing refreshes the goal rather
        # than creating a second mission for the same ticket.
        {:ok, :deduped, mission}
    end
  end

  # -- Mission creation --------------------------------------------------------

  defp create(issue, key, sector_id, priority) do
    fields = Map.get(issue, "fields") || %{}
    summary = Map.get(fields, "summary") || key
    type = get_in(fields, ["issuetype", "name"]) || "Task"
    description = fields |> Map.get("description") |> describe()

    goal =
      """
      #{type}: #{summary}

      Jira: #{key}
      #{if description != "", do: "\n" <> description, else: ""}
      """
      |> String.trim()

    attrs = %{
      goal: goal,
      name: "#{key}: #{String.slice(summary, 0, 60)}",
      sector_id: sector_id,
      source: "jira_issue",
      source_issue: %{key: key, project: get_in(fields, ["project", "key"])},
      priority: priority
    }

    case Missions.create(attrs) do
      {:ok, mission} ->
        Logger.info(
          "Jira webhook: created mission #{mission.id} for #{key} (sector=#{sector_id})"
        )

        {:ok, :admitted, mission}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Jira sends either a plain string (v2 API) or an Atlassian Document Format
  # tree (v3). Walking ADF for text keeps the goal readable instead of
  # embedding a JSON blob the phase ghost has to reverse-engineer.
  defp describe(nil), do: ""
  defp describe(text) when is_binary(text), do: String.slice(text, 0, 4000)

  defp describe(%{"content" => content}) when is_list(content) do
    content |> Enum.map_join("\n", &adf_text/1) |> String.trim() |> String.slice(0, 4000)
  end

  defp describe(_), do: ""

  defp adf_text(%{"text" => text}) when is_binary(text), do: text

  defp adf_text(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, &adf_text/1)

  defp adf_text(_), do: ""

  defp find_existing(sector_id, key) do
    Archive.find_one(:missions, fn m ->
      m[:sector_id] == sector_id and get_in(m, [:source_issue, :key]) == key
    end)
  end

  defp project_map do
    Application.get_env(:gitf, :jira_project_to_sector, %{})
  end

  defp bot_account do
    Application.get_env(:gitf, :jira_bot_account) || System.get_env("GITF_JIRA_BOT_ACCOUNT")
  end
end
