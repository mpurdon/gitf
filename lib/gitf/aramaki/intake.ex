defmodule GiTF.Aramaki.Intake do
  @moduledoc """
  Turns an inbound GitHub `issues` webhook event into a deduped, admission-
  gated **pending** mission.

  Intake does NOT start the mission — it only creates it (gated by
  `Aramaki.Policy`) and hands it to the `GiTF.Aramaki` server, which admits
  work within capacity. Dedup is keyed by `{repo, issue_number}` so re-labeling
  or editing an already-ingested issue updates rather than duplicates.
  """

  require Logger

  alias GiTF.Aramaki.Policy

  @actions ~w(opened labeled reopened edited)

  @doc """
  Dispatches a GitHub `issues` webhook payload. Returns one of:

    * `{:ok, :admitted, mission}` — new pending mission created
    * `{:ok, :deduped, mission}` — existing mission for this issue
    * `{:ok, :ignored, reason}` — not labeled / bot activity / untracked repo
    * `{:error, reason}`
  """
  @spec dispatch(map()) ::
          {:ok, :admitted | :deduped, map()} | {:ok, :ignored, atom()} | {:error, term()}
  def dispatch(%{"action" => action, "issue" => issue, "repository" => repo})
      when action in @actions do
    case Policy.admit_issue?(issue, bot_login: bot_login()) do
      {:reject, reason} ->
        {:ok, :ignored, reason}

      {:admit, priority} ->
        case GiTF.Sector.by_github(repo["full_name"]) do
          {:ok, sector} -> upsert_mission(sector, repo, issue, priority)
          :error -> {:ok, :ignored, :untracked_repo}
        end
    end
  end

  def dispatch(_), do: {:ok, :ignored, :irrelevant_action}

  @doc "Stable dedup key for an issue: `owner/repo#number`."
  @spec issue_key(String.t(), integer()) :: String.t()
  def issue_key(repo_full_name, number), do: "#{repo_full_name}##{number}"

  defp upsert_mission(sector, repo, issue, priority) do
    key = issue_key(repo["full_name"], issue["number"])

    case existing_mission(key) do
      nil ->
        goal = build_goal(issue)

        attrs = %{
          goal: goal,
          sector_id: sector.id,
          name: "issue-#{issue["number"]}: #{String.slice(issue["title"] || "", 0, 60)}",
          source: "github_issue",
          source_issue: %{
            key: key,
            repo: repo["full_name"],
            number: issue["number"],
            url: issue["html_url"]
          },
          aramaki_priority: priority
        }

        case GiTF.Missions.create(attrs) do
          {:ok, mission} ->
            Logger.info("Aramaki: admitted issue #{key} → pending mission #{mission.id}")
            notify_server(mission)
            {:ok, :admitted, mission}

          {:error, reason} ->
            {:error, reason}
        end

      mission ->
        {:ok, :deduped, mission}
    end
  end

  defp existing_mission(key) do
    GiTF.Archive.all(:missions)
    |> Enum.find(fn m -> get_in(m, [:source_issue, :key]) == key end)
  end

  defp build_goal(issue) do
    title = issue["title"] || "Untitled issue"
    body = issue["body"] || ""
    "#{title}\n\n#{String.slice(body, 0, 4_000)}"
  end

  # The factory's own bot login — issues it opens are ignored (loop prevention).
  defp bot_login do
    Application.get_env(:gitf, :aramaki, []) |> Keyword.get(:bot_login)
  end

  defp notify_server(mission) do
    if pid = Process.whereis(GiTF.Aramaki) do
      send(pid, {:consider, mission.id})
    end

    :ok
  end
end
