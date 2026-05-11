defmodule GiTF.Sentry.InboundTest do
  use GiTF.StoreCase

  alias GiTF.Sentry.Inbound

  setup do
    prior_map = Application.get_env(:gitf, :sentry_project_to_sector)
    prior_actions = Application.get_env(:gitf, :sentry_trigger_actions)

    Application.put_env(:gitf, :sentry_project_to_sector, %{
      "frontend-app" => "sec-frontend",
      "api-server" => "sec-api"
    })

    Application.put_env(:gitf, :sentry_trigger_actions, ["created", "triggered"])

    GiTF.Archive.all(:missions)
    |> Enum.each(fn m -> GiTF.Archive.delete(:missions, m.id) end)

    on_exit(fn ->
      Application.put_env(:gitf, :sentry_project_to_sector, prior_map)
      Application.put_env(:gitf, :sentry_trigger_actions, prior_actions)
    end)

    :ok
  end

  defp issue_payload(opts \\ []) do
    issue_id = Keyword.get(opts, :issue_id, "1234567")
    project = Keyword.get(opts, :project, "frontend-app")
    title = Keyword.get(opts, :title, "TypeError: cannot read property 'foo' of undefined")
    short_id = Keyword.get(opts, :short_id, "PROJ-42")

    %{
      "action" => Keyword.get(opts, :action, "created"),
      "data" => %{
        "issue" => %{
          "id" => issue_id,
          "title" => title,
          "shortId" => short_id,
          "permalink" => "https://sentry.io/organizations/acme/issues/#{issue_id}/",
          "level" => "error",
          "culprit" => "src/components/Foo.tsx in render",
          "metadata" => %{"type" => "TypeError", "value" => "cannot read property 'foo' of undefined"},
          "project" => %{"slug" => project}
        }
      }
    }
  end

  describe "dispatch/1 — happy path" do
    test "creates a mission for a created issue in a mapped project" do
      assert {:ok, :created, mission} = Inbound.dispatch(issue_payload())

      assert mission.sector_id == "sec-frontend"
      assert mission.issue_ref["source"] == "sentry"
      assert mission.issue_ref["issue_id"] == "1234567"
      assert mission.issue_ref["short_id"] == "PROJ-42"
      assert mission.artifacts["sentry"]["occurrences"] == 1
      assert mission.artifacts["sentry"]["first_seen_action"] == "created"
      assert mission.name =~ "Sentry: TypeError"
      assert mission.goal =~ "Investigate Sentry error"
      assert mission.goal =~ "Short ID: PROJ-42"
    end

    test "routes to the project's mapped sector" do
      assert {:ok, :created, mission} = Inbound.dispatch(issue_payload(project: "api-server"))
      assert mission.sector_id == "sec-api"
    end
  end

  describe "dispatch/1 — dedup" do
    test "second event for same issue+sector bumps occurrences instead of creating" do
      assert {:ok, :created, m1} = Inbound.dispatch(issue_payload())
      assert {:ok, :deduped, m2} = Inbound.dispatch(issue_payload(action: "triggered"))

      assert m1.id == m2.id
      assert m2.artifacts["sentry"]["occurrences"] == 2
      assert m2.artifacts["sentry"]["last_seen_action"] == "triggered"
    end

    test "different issue ids in same sector each create their own mission" do
      assert {:ok, :created, m1} = Inbound.dispatch(issue_payload(issue_id: "111"))
      assert {:ok, :created, m2} = Inbound.dispatch(issue_payload(issue_id: "222"))
      refute m1.id == m2.id
    end

    test "same issue id in different sectors creates separate missions" do
      assert {:ok, :created, m1} =
               Inbound.dispatch(issue_payload(issue_id: "555", project: "frontend-app"))

      assert {:ok, :created, m2} =
               Inbound.dispatch(issue_payload(issue_id: "555", project: "api-server"))

      refute m1.id == m2.id
      assert m1.sector_id != m2.sector_id
    end

    test "closed mission for same issue does NOT block a new mission" do
      assert {:ok, :created, m1} = Inbound.dispatch(issue_payload())
      {:ok, _} = GiTF.Archive.update(:missions, m1.id, fn m -> Map.put(m, :status, "closed") end)

      assert {:ok, :created, m2} = Inbound.dispatch(issue_payload(action: "triggered"))
      refute m1.id == m2.id
    end
  end

  describe "dispatch/1 — ignored cases" do
    test "ignores resolution events" do
      assert {:ok, :ignored, :action_not_triggered} =
               Inbound.dispatch(issue_payload(action: "resolved"))
    end

    test "ignores unmapped projects" do
      assert {:ok, :ignored, :project_not_mapped} =
               Inbound.dispatch(issue_payload(project: "ghost-service"))
    end
  end

  describe "dispatch/1 — error cases" do
    test "rejects payload missing action" do
      assert {:error, :missing_action} = Inbound.dispatch(%{"data" => %{}})
    end

    test "rejects payload missing issue" do
      assert {:error, :missing_issue} = Inbound.dispatch(%{"action" => "created", "data" => %{}})
    end

    test "rejects payload missing project" do
      payload = %{
        "action" => "created",
        "data" => %{"issue" => %{"id" => "x", "title" => "t"}}
      }

      assert {:error, :missing_project} = Inbound.dispatch(payload)
    end

    test "rejects non-map payload" do
      assert {:error, :invalid_payload} = Inbound.dispatch("not a payload")
    end
  end
end
