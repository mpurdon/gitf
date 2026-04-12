defmodule GiTF.Dashboard.Router do
  @moduledoc "Routes for the GiTF web dashboard."

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {GiTF.Dashboard.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", GiTF.Dashboard do
    pipe_through(:browser)

    live("/", OverviewLive)
    live("/missions/new", MissionNewLive)
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
    live("/autonomy", AutonomyLive)
    live("/settings", SettingsLive)
  end
end
