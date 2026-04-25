defmodule GiTF.Web.WebhookControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GiTF.Web.WebhookController

  @secret "test-secret-1234567890"

  setup do
    prior_enabled = Application.get_env(:gitf, :webhooks_enabled, false)
    prior_secret = Application.get_env(:gitf, :github_webhook_secret)
    prior_outcomes = Application.get_env(:gitf, :outcomes_enabled, false)

    Application.put_env(:gitf, :webhooks_enabled, true)
    Application.put_env(:gitf, :github_webhook_secret, @secret)
    Application.put_env(:gitf, :outcomes_enabled, true)

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    on_exit(fn ->
      Application.put_env(:gitf, :webhooks_enabled, prior_enabled)
      Application.put_env(:gitf, :github_webhook_secret, prior_secret)
      Application.put_env(:gitf, :outcomes_enabled, prior_outcomes)
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
end
