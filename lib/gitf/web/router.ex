defmodule GiTF.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(GiTF.Web.TailnetAuth)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {GiTF.Web.Layout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api_public do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 600,
      window_seconds: 60,
      bucket: :api_public
    )
  end

  # Webhook receivers — HMAC-authenticated by the controller, so no API
  # key gate. Generous rate limit to absorb event bursts (deploy storms,
  # multi-PR merges).
  pipeline :webhooks do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 1_000,
      window_seconds: 60,
      bucket: :webhooks
    )
  end

  pipeline :api do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 60,
      window_seconds: 60,
      bucket: :api
    )

    plug(:require_local_or_api_key)
  end

  pipeline :metrics do
    plug(:accepts, ["json", "text"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 600,
      window_seconds: 60,
      bucket: :metrics
    )

    plug(:require_local_or_api_key)
  end

  pipeline :dashboard do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(GiTF.Web.TailnetAuth)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {GiTF.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", GiTF.Web do
    pipe_through(:browser)

    live_session :root, on_mount: GiTF.Web.TailnetAuth do
      live("/", Live.Dashboard)
    end
  end

  scope "/dashboard", GiTF.Dashboard do
    pipe_through(:dashboard)

    live_session :dashboard, on_mount: GiTF.Web.TailnetAuth do
      live("/", OverviewLive)
      live("/studio", StudioLive)
      live("/studio/:session_id", StudioLive)
      live("/missions/new", MissionNewLive)
      live("/missions/:id/diagnostics", MissionDiagnosticsLive)
      live("/missions/:id/design", DesignLive)
      live("/missions/:id/plan", PlanLive)
      live("/missions/:id", MissionDetailLive)
      live("/missions", MissionsLive)
      live("/ghosts", GhostsLive)
      live("/costs", CostsLive)
      live("/models", ModelPerformanceLive)
      live("/links", LinksLive)
      live("/progress", ProgressLive)
      live("/approvals", ApprovalsLive)
      live("/ops/:id", OpDetailLive)
      live("/sectors", SectorsLive)
      live("/workflows", WorkflowsLive)
      live("/workflows/:name", WorkflowEditorLive)
      live("/autonomy", AutonomyLive)
      live("/providers", ProvidersLive)
      live("/health", HealthLive)
      live("/shells", ShellsLive)
      live("/timeline", TimelineLive)
      live("/timeline/:mission_id", TimelineLive)
      live("/rollback", RollbackLive)
      live("/merges", MergeQueueLive)
      live("/settings", SettingsLive)
    end
  end

  # Liveness probe — process alive, no auth
  scope "/api/v1", GiTF.Web do
    pipe_through(:api_public)
    get("/health", ApiController, :health)
    get("/health/deep", ApiController, :deep_health)
    get("/ready", ApiController, :ready)
    get("/version", ApiController, :version)
  end

  # Inbound webhooks — HMAC-verified by controller.
  scope "/api/v1/webhooks", GiTF.Web do
    pipe_through(:webhooks)
    post("/github", WebhookController, :github)
    post("/sentry", WebhookController, :sentry)
  end

  # Metrics — auth required (local bypass gated by config + optional
  # x-forwarded-for trust). Prometheus scrapers should provide an API key.
  scope "/api/v1", GiTF.Web do
    pipe_through(:metrics)
    get("/metrics", ApiController, :metrics)
  end

  scope "/api/v1", GiTF.Web do
    pipe_through(:api)

    # Quests
    post("/missions", ApiController, :create_quest)
    get("/missions", ApiController, :list_quests)
    get("/missions/:id", ApiController, :show_quest)
    delete("/missions/:id", ApiController, :delete_quest)
    put("/missions/:id/priority", ApiController, :update_quest_priority)
    post("/missions/:id/kill", ApiController, :kill_quest)
    post("/missions/:id/close", ApiController, :close_quest)
    post("/missions/:id/start", ApiController, :start_quest)
    get("/missions/:id/status", ApiController, :quest_status)
    post("/missions/:id/plan", ApiController, :plan_quest)
    get("/missions/:id/report", ApiController, :quest_report)
    post("/missions/:id/sync", ApiController, :quest_merge)
    get("/missions/:id/spec/:phase", ApiController, :quest_spec_show)
    put("/missions/:id/spec/:phase", ApiController, :quest_spec_write)
    post("/missions/:id/plan/confirm", ApiController, :confirm_plan)
    post("/missions/:id/plan/reject", ApiController, :reject_plan)
    post("/missions/:id/plan/revise", ApiController, :revise_plan)
    get("/missions/:id/plan/candidates", ApiController, :list_plan_candidates)
    post("/missions/:id/plan/select", ApiController, :select_plan_candidate)

    # Jobs
    get("/ops", ApiController, :list_jobs)
    get("/ops/:id", ApiController, :show_job)
    post("/ops/:id/reset", ApiController, :reset_job)
    delete("/ops/:id", ApiController, :kill_job)

    # Ghosts
    get("/ghosts", ApiController, :list_bees)
    post("/ghosts/:id/stop", ApiController, :stop_ghost)
    post("/ghosts/:id/complete", ApiController, :complete_bee)
    post("/ghosts/:id/fail", ApiController, :fail_bee)

    # Projects (Aramaki multi-mission initiatives)
    post("/projects", ApiController, :create_project)
    get("/projects", ApiController, :list_projects)
    get("/projects/:id", ApiController, :show_project)
    post("/projects/:id/approve", ApiController, :approve_project)
    post("/projects/:id/pause", ApiController, :pause_project)
    post("/projects/:id/resume", ApiController, :resume_project)
    put("/projects/:id/roadmap", ApiController, :update_project_roadmap)

    # Sectors
    post("/sectors", ApiController, :add_sector)
    get("/sectors", ApiController, :list_sectors)
    get("/sectors/:id", ApiController, :show_sector)
    put("/sectors/:id", ApiController, :update_sector)
    delete("/sectors/:id", ApiController, :remove_sector)
    post("/sectors/:id/use", ApiController, :use_sector)

    # Costs
    get("/costs/summary", ApiController, :costs_summary)
    post("/costs/record", ApiController, :record_cost)

    # MCP bridge (JSON-RPC over HTTP for remote `gitf mcp-serve`)
    post("/mcp", ApiController, :mcp)
  end

  # Restrict API to localhost unless a valid API key is provided.
  # The API key is read from the section config file (api_key field).
  #
  # Local-IP auth bypass is gated by config:
  #   config :gitf, :local_ip_bypass, true | false   (default: true in dev, false in prod)
  #   config :gitf, :trust_x_forwarded_for, false    (if true, uses X-Forwarded-For for local? check)
  #
  # In reverse-proxied deployments all traffic appears as 127.0.0.1, so the
  # bypass is unsafe unless explicitly enabled and (optionally) XFF is trusted.
  defp require_local_or_api_key(conn, _opts) do
    bypass_enabled? = Application.get_env(:gitf, :local_ip_bypass, false)
    trust_xff? = Application.get_env(:gitf, :trust_x_forwarded_for, false)

    remote_ip =
      if trust_xff? do
        case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
          [xff | _] ->
            xff
            |> String.split(",")
            |> List.first()
            |> String.trim()
            |> parse_ip(conn.remote_ip)

          _ ->
            conn.remote_ip
        end
      else
        conn.remote_ip
      end

    if bypass_enabled? and local_ip?(remote_ip) do
      conn
    else
      case Plug.Conn.get_req_header(conn, "x-api-key") do
        [key] when byte_size(key) > 0 ->
          if valid_api_key?(key) do
            conn
          else
            conn
            |> Plug.Conn.put_status(401)
            |> Phoenix.Controller.json(%{error: "invalid API key"})
            |> Plug.Conn.halt()
          end

        _ ->
          conn
          |> Plug.Conn.put_status(401)
          |> Phoenix.Controller.json(%{error: "API key required for non-local requests"})
          |> Plug.Conn.halt()
      end
    end
  end

  defp local_ip?({127, 0, 0, 1}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?(_), do: false

  defp parse_ip(str, fallback) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> ip
      _ -> fallback
    end
  end

  defp valid_api_key?(key) do
    case GiTF.Config.api_key() do
      nil -> false
      configured_key -> Plug.Crypto.secure_compare(key, configured_key)
    end
  end
end
