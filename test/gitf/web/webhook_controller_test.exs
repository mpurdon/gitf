defmodule GiTF.Web.WebhookControllerTest do
  use GiTF.StoreCase

  import Phoenix.ConnTest

  alias GiTF.Web.WebhookController

  @secret "test-secret-1234567890"

  setup do
    prior_enabled = Application.get_env(:gitf, :webhooks_enabled, false)
    prior_secret = Application.get_env(:gitf, :github_webhook_secret)
    prior_outcomes = Application.get_env(:gitf, :outcomes_enabled, false)
    prior_sentry_secret = Application.get_env(:gitf, :sentry_webhook_secret)
    prior_sentry_map = Application.get_env(:gitf, :sentry_project_to_sector)

    Application.put_env(:gitf, :webhooks_enabled, true)
    Application.put_env(:gitf, :github_webhook_secret, @secret)
    Application.put_env(:gitf, :sentry_webhook_secret, @secret)
    Application.put_env(:gitf, :sentry_project_to_sector, %{"frontend-app" => "sec-fe"})
    Application.put_env(:gitf, :outcomes_enabled, true)

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    GiTF.Archive.all(:missions)
    |> Enum.each(fn m -> GiTF.Archive.delete(:missions, m.id) end)

    on_exit(fn ->
      Application.put_env(:gitf, :webhooks_enabled, prior_enabled)
      Application.put_env(:gitf, :github_webhook_secret, prior_secret)
      Application.put_env(:gitf, :outcomes_enabled, prior_outcomes)
      Application.put_env(:gitf, :sentry_webhook_secret, prior_sentry_secret)
      Application.put_env(:gitf, :sentry_project_to_sector, prior_sentry_map)
    end)

    :ok
  end

  defp conn_with_body(body, signature) do
    headers = [
      {"content-type", "application/json"},
      {"x-github-event", "pull_request"},
      {"x-hub-signature-256", signature}
    ]

    conn = build_conn(:post, "/api/v1/webhooks/github", body)

    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    |> Plug.Conn.assign(:raw_body, body)
    |> Map.put(:body_params, Jason.decode!(body))
  end

  defp valid_signature(body) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower))
  end

  defp pr_payload(url) do
    Jason.encode!(%{
      action: "closed",
      pull_request: %{
        html_url: url,
        merged: true,
        state: "closed"
      }
    })
  end

  describe "github/2 — signature verification" do
    test "401 when X-Hub-Signature-256 is missing" do
      body = pr_payload("https://github.com/x/y/pull/1")
      conn = conn_with_body(body, "")
      conn = WebhookController.github(conn, conn.body_params)
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "invalid signature"
    end

    test "401 when signature does not match" do
      body = pr_payload("https://github.com/x/y/pull/1")
      conn = conn_with_body(body, "sha256=00deadbeef")
      conn = WebhookController.github(conn, conn.body_params)
      assert conn.status == 401
    end

    test "200 with valid signature" do
      body = pr_payload("https://github.com/x/y/pull/1")
      conn = conn_with_body(body, valid_signature(body))
      conn = WebhookController.github(conn, conn.body_params)
      assert json_response(conn, 200) == %{"ok" => true, "event" => "pull_request"}
    end
  end

  describe "github/2 — feature flag" do
    test "503 when :webhooks_enabled is false" do
      Application.put_env(:gitf, :webhooks_enabled, false)
      body = pr_payload("https://github.com/x/y/pull/1")
      conn = conn_with_body(body, valid_signature(body))
      conn = WebhookController.github(conn, conn.body_params)
      assert conn.status == 503
    end
  end

  describe "github/2 — pull_request event" do
    test "ignores PR not tracked (no outcome)" do
      body = pr_payload("https://github.com/unknown/repo/pull/99")
      conn = conn_with_body(body, valid_signature(body))
      conn = WebhookController.github(conn, conn.body_params)
      assert json_response(conn, 200) == %{"ok" => true, "event" => "pull_request"}
    end

    test "bumps next_poll_at on a tracked PR" do
      # The webhook handler fires `Outcomes.Tracker.tick/0` after bumping the
      # record. That async poll would resolve no repo_path for this synthetic
      # sector and `stop_tracking` the outcome (nulling next_poll_at) before we
      # can observe the bump — so take the Tracker out of the picture for this
      # test and restore it afterwards.
      if Process.whereis(GiTF.Outcomes.Tracker) do
        :ok = Supervisor.terminate_child(GiTF.Core.Supervisor, GiTF.Outcomes.Tracker)
        on_exit(fn -> Supervisor.restart_child(GiTF.Core.Supervisor, GiTF.Outcomes.Tracker) end)
      end

      mission = %{id: "msn-wh-1", sector_id: "sec-wh"}
      pr_url = "https://github.com/test/repo/pull/42"
      {:ok, outcome} = GiTF.Outcomes.start_tracking(mission, pr_url)

      # Push next_poll_at into the future so we can detect the bump back to ~now.
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = GiTF.Outcomes.update(outcome.id, fn o -> Map.put(o, :next_poll_at, future) end)

      body = pr_payload(pr_url)
      conn = conn_with_body(body, valid_signature(body))
      conn = WebhookController.github(conn, conn.body_params)
      assert json_response(conn, 200) == %{"ok" => true, "event" => "pull_request"}

      updated = GiTF.Outcomes.get(outcome.id)
      assert DateTime.compare(updated.next_poll_at, future) == :lt
    end
  end

  describe "github/2 — ping event" do
    test "200 with ok=true on ping" do
      body = Jason.encode!(%{zen: "Speak like a human."})

      conn =
        build_conn(:post, "/api/v1/webhooks/github", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-github-event", "ping")
        |> Plug.Conn.put_req_header("x-hub-signature-256", valid_signature(body))
        |> Plug.Conn.assign(:raw_body, body)
        |> Map.put(:body_params, Jason.decode!(body))

      conn = WebhookController.github(conn, conn.body_params)
      assert json_response(conn, 200) == %{"ok" => true, "event" => "ping"}
    end
  end

  # -- Sentry endpoint -------------------------------------------------------

  defp sentry_signature(body) do
    :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)
  end

  defp sentry_conn(body, signature) do
    build_conn(:post, "/api/v1/webhooks/sentry", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("sentry-hook-signature", signature)
    |> Plug.Conn.assign(:raw_body, body)
    |> Map.put(:body_params, Jason.decode!(body))
  end

  defp sentry_issue_body(opts \\ []) do
    Jason.encode!(%{
      action: Keyword.get(opts, :action, "created"),
      data: %{
        issue: %{
          id: Keyword.get(opts, :issue_id, "9001"),
          title: "BadThingError",
          shortId: "FE-1",
          permalink: "https://sentry.io/organizations/x/issues/9001/",
          level: "error",
          culprit: "main.js:1",
          metadata: %{type: "BadThingError", value: "boom"},
          project: %{slug: Keyword.get(opts, :project, "frontend-app")}
        }
      }
    })
  end

  describe "sentry/2 — signature verification" do
    test "401 when sentry-hook-signature is missing" do
      body = sentry_issue_body()
      conn = sentry_conn(body, "")
      conn = WebhookController.sentry(conn, conn.body_params)
      assert conn.status == 401
    end

    test "401 when signature does not match" do
      body = sentry_issue_body()
      conn = sentry_conn(body, "deadbeef")
      conn = WebhookController.sentry(conn, conn.body_params)
      assert conn.status == 401
    end

    test "200 with valid signature creates a mission" do
      body = sentry_issue_body()
      conn = sentry_conn(body, sentry_signature(body))
      conn = WebhookController.sentry(conn, conn.body_params)
      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["result"] == "created"
    end
  end

  describe "sentry/2 — feature flag" do
    test "503 when :webhooks_enabled is false" do
      Application.put_env(:gitf, :webhooks_enabled, false)
      body = sentry_issue_body()
      conn = sentry_conn(body, sentry_signature(body))
      conn = WebhookController.sentry(conn, conn.body_params)
      assert conn.status == 503
    end
  end

  describe "sentry/2 — dispatch outcomes" do
    test "deduped on a repeat issue" do
      body1 = sentry_issue_body(issue_id: "777")
      conn1 = sentry_conn(body1, sentry_signature(body1)) |> WebhookController.sentry(%{})
      assert json_response(conn1, 200)["result"] == "created"

      body2 = sentry_issue_body(issue_id: "777", action: "triggered")
      conn2 = sentry_conn(body2, sentry_signature(body2)) |> WebhookController.sentry(%{})
      assert json_response(conn2, 200)["result"] == "deduped"
    end

    test "ignored on unmapped project" do
      body = sentry_issue_body(project: "unmapped-svc")
      conn = sentry_conn(body, sentry_signature(body)) |> WebhookController.sentry(%{})
      assert json_response(conn, 200)["result"] == "project_not_mapped"
    end

    test "ignored on resolution events" do
      body = sentry_issue_body(action: "resolved")
      conn = sentry_conn(body, sentry_signature(body)) |> WebhookController.sentry(%{})
      assert json_response(conn, 200)["result"] == "action_not_triggered"
    end
  end
end
