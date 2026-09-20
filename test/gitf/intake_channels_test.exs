defmodule GiTF.IntakeChannelsTest do
  @moduledoc """
  Every intake channel must reach the factory the same way.

  The defect that prompted this: Sentry created missions directly, without a
  `source` field, so `GiTF.Aramaki` — which only auto-starts missions whose
  source is in `@owned_sources`, and deliberately never starts source-nil
  "operator-created" work — silently ignored every one of them. A Sentry
  alert produced a pending mission that nothing would ever start, and nothing
  reported it. The Sentry path was also ungated, so this happened even with
  the admission layer switched off.

  These tests pin the shared contract: admitted work carries a source Aramaki
  owns, and each channel has its own admission predicate over one shared
  ceiling.
  """
  use GiTF.StoreCase

  alias GiTF.Aramaki.Policy
  alias GiTF.Jira.Inbound, as: Jira
  alias GiTF.Sentry.Inbound, as: Sentry

  @sector "sec-intake-test"

  setup do
    {:ok, _} = GiTF.Archive.insert(:sectors, %{id: @sector, name: "intake-test"})

    prev_sentry = Application.get_env(:gitf, :sentry_project_to_sector)
    prev_jira = Application.get_env(:gitf, :jira_project_to_sector)
    Application.put_env(:gitf, :sentry_project_to_sector, %{"frontend" => @sector})
    Application.put_env(:gitf, :jira_project_to_sector, %{"PROJ" => @sector})

    on_exit(fn ->
      Application.put_env(:gitf, :sentry_project_to_sector, prev_sentry)
      Application.put_env(:gitf, :jira_project_to_sector, prev_jira)
    end)

    :ok
  end

  # The exact list Aramaki will auto-start. If a channel's source is not in
  # here, its missions sit pending forever.
  defp owned_sources do
    "lib/gitf/aramaki.ex"
    |> File.read!()
    |> then(&Regex.run(~r/@owned_sources ~w\(([^)]+)\)/, &1))
    |> List.last()
    |> String.split()
  end

  defp sentry_payload(level, opts \\ []) do
    %{
      "action" => "created",
      "data" => %{
        "issue" => %{
          "id" => Keyword.get(opts, :id, "99#{:rand.uniform(9999)}"),
          "title" => "NoMethodError in checkout",
          "shortId" => "FE-7",
          "level" => level,
          "project" => %{"slug" => "frontend"}
        }
      }
    }
  end

  defp jira_payload(labels, opts \\ []) do
    %{
      "webhookEvent" => "jira:issue_created",
      "issue" => %{
        "key" => Keyword.get(opts, :key, "PROJ-#{:rand.uniform(9999)}"),
        "fields" => %{
          "summary" => "Checkout throws on empty cart",
          "description" => Keyword.get(opts, :description, "Steps to reproduce..."),
          "labels" => labels,
          "issuetype" => %{"name" => Keyword.get(opts, :type, "Bug")},
          "status" => %{"statusCategory" => %{"key" => "indeterminate"}},
          "project" => %{"key" => "PROJ"}
        }
      }
    }
  end

  describe "the regression that started this" do
    test "a Sentry mission carries a source Aramaki will actually start" do
      assert {:ok, :created, mission} = Sentry.dispatch(sentry_payload("error"))

      assert mission.source == "sentry",
             "a source-less mission is treated as operator-created and never auto-started"

      assert mission.source in owned_sources(),
             "Aramaki does not own #{inspect(mission.source)}; the mission will sit pending forever"
    end

    test "every intake channel's source is one Aramaki owns" do
      owned = owned_sources()

      for source <- ~w(github_issue jira_issue sentry) do
        assert source in owned, "#{source} missions would never start"
      end
    end
  end

  describe "Sentry admission — severity is the gate" do
    test "errors and fatals become missions" do
      assert {:ok, :created, _} = Sentry.dispatch(sentry_payload("error"))
      assert {:ok, :created, _} = Sentry.dispatch(sentry_payload("fatal"))
    end

    test "warnings and info are monitoring signal, not work" do
      for level <- ~w(warning info debug) do
        assert {:ok, :ignored, :level_below_threshold} =
                 Sentry.dispatch(sentry_payload(level)),
               "#{level} was admitted as a mission"
      end
    end

    test "a fatal outranks an error in the shared queue" do
      assert {:admit, 0} = Policy.admit_sentry?(%{"level" => "fatal"})
      assert {:admit, 1} = Policy.admit_sentry?(%{"level" => "error"})
    end

    test "an already-resolved issue is not actionable" do
      assert {:reject, :not_actionable} =
               Policy.admit_sentry?(%{"level" => "error", "status" => "resolved"})
    end

    test "recurrences dedupe rather than creating a second mission" do
      payload = sentry_payload("error", id: "fixed-id-1")

      assert {:ok, :created, first} = Sentry.dispatch(payload)
      assert {:ok, :deduped, second} = Sentry.dispatch(payload)
      assert first.id == second.id
    end
  end

  describe "Jira admission — the label is the gate" do
    test "a labelled ticket becomes a pending mission" do
      assert {:ok, :admitted, mission} = Jira.dispatch(jira_payload(["gitf:build"]))
      assert mission.source == "jira_issue"
      assert mission.sector_id == @sector
      assert mission.name =~ "PROJ-"
    end

    test "an unlabelled ticket is ignored" do
      # Same untrusted-input reasoning as GitHub: a description is
      # attacker-controllable wherever outside reporters can file.
      assert {:ok, :ignored, :not_labeled} = Jira.dispatch(jira_payload([]))
      assert {:ok, :ignored, :not_labeled} = Jira.dispatch(jira_payload(["bug"]))
    end

    test "a done ticket is not reopened as work" do
      payload = jira_payload(["gitf:build"])

      payload =
        put_in(payload, ["issue", "fields", "status"], %{"statusCategory" => %{"key" => "done"}})

      assert {:ok, :ignored, :closed} = Jira.dispatch(payload)
    end

    test "an unmapped project is dropped without leaking that it is unmapped" do
      payload = jira_payload(["gitf:build"])
      payload = put_in(payload, ["issue", "fields", "project"], %{"key" => "OTHER"})

      assert {:ok, :ignored, :project_not_mapped} = Jira.dispatch(payload)
    end

    test "the same ticket twice dedupes on its key" do
      payload = jira_payload(["gitf:build"], key: "PROJ-555")

      assert {:ok, :admitted, first} = Jira.dispatch(payload)
      assert {:ok, :deduped, second} = Jira.dispatch(payload)
      assert first.id == second.id
    end

    test "issue type orders the queue when labels do not" do
      assert {:admit, 1} = Policy.admit_jira?(labelled_fields("Bug", ["gitf:build"]))
      assert {:admit, 3} = Policy.admit_jira?(labelled_fields("Story", ["gitf:build"]))
      assert {:admit, 0} = Policy.admit_jira?(labelled_fields("Task", ["gitf:build", "security"]))
    end

    test "an Atlassian Document Format description is flattened to readable text" do
      adf = %{
        "content" => [
          %{"content" => [%{"text" => "The cart explodes"}]},
          %{"content" => [%{"text" => "when empty."}]}
        ]
      }

      payload = jira_payload(["gitf:build"], description: adf)

      assert {:ok, :admitted, mission} = Jira.dispatch(payload)
      assert mission.goal =~ "The cart explodes"
      refute mission.goal =~ "content"
    end

    test "events we do not act on are ignored" do
      payload = %{jira_payload(["gitf:build"]) | "webhookEvent" => "jira:issue_deleted"}
      assert {:ok, :ignored, :event_not_triggered} = Jira.dispatch(payload)
    end

    test "a malformed payload is an error, not a crash" do
      for bad <- [%{}, %{"webhookEvent" => "jira:issue_created"}, "nonsense", nil] do
        assert {:error, _} = Jira.dispatch(bad), inspect(bad)
      end
    end
  end

  defp labelled_fields(type, labels) do
    %{
      "fields" => %{
        "labels" => labels,
        "issuetype" => %{"name" => type},
        "status" => %{"statusCategory" => %{"key" => "indeterminate"}}
      }
    }
  end
end
