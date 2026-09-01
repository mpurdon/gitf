defmodule GiTF.Web.CabinetRouter do
  @moduledoc """
  The Cabinet's ENTIRE web surface. In cabinet mode the endpoint
  dispatches here instead of `GiTF.Web.Router`, so factory routes do not
  exist — not 404-with-a-message; not routed at all. That is the hard
  boundary that keeps the Cabinet from being the factory dashboard with
  a page bolted on (GiTF Control Surface plan, Phase 0).

  What the Cabinet serves:

    * `/` — the Console (fleet, inbox, policy; `GiTF.Dashboard.CabinetLive`)
    * `POST /hooks/:ministry` — webhook ingress, HMAC per ministry
    * `/api/v1/health` `/version` `/ready` — public probes
    * `POST /api/v1/mcp` — the Cabinet's MCP bridge (cabinet tool set only)
    * `/metrics` — Prometheus

  `test/gitf/web/cabinet_boundary_test.exs` fails the build if a factory
  route or tool becomes reachable in cabinet mode.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :dashboard do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(GiTF.Web.TailnetAuth)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {GiTF.Dashboard.CabinetLayouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :webhooks do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 1_000,
      window_seconds: 60,
      bucket: :webhooks
    )
  end

  pipeline :api_public do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 600,
      window_seconds: 60,
      bucket: :api_public
    )
  end

  pipeline :api do
    plug(:accepts, ["json"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 60,
      window_seconds: 60,
      bucket: :api
    )

    plug(GiTF.Web.ApiKeyGate)
  end

  pipeline :metrics do
    plug(:accepts, ["json", "text"])

    plug(GiTF.Web.RateLimitPlug,
      max_requests: 600,
      window_seconds: 60,
      bucket: :metrics
    )

    plug(GiTF.Web.ApiKeyGate)
  end

  scope "/", GiTF.Dashboard do
    pipe_through(:dashboard)

    live_session :cabinet, on_mount: GiTF.Web.TailnetAuth do
      live("/", CabinetLive)
    end
  end

  scope "/hooks", GiTF.Web do
    pipe_through(:webhooks)
    post("/:ministry", CabinetHookController, :receive)
  end

  scope "/api/v1", GiTF.Web do
    pipe_through(:api_public)
    get("/health", ApiController, :health)
    get("/ready", ApiController, :ready)
    get("/version", ApiController, :version)
  end

  scope "/api/v1", GiTF.Web do
    pipe_through(:api)
    post("/mcp", ApiController, :mcp)
  end

  scope "/", GiTF.Web do
    pipe_through(:metrics)
    get("/metrics", ApiController, :metrics)
  end
end
