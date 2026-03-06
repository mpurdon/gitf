defmodule Hive.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Hive.Web.Layout, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Hive.Web do
    pipe_through :browser

    live "/", Live.Dashboard
  end

  scope "/api/v1", Hive.Web do
    pipe_through :api

    get "/health", ApiController, :health

    # Quests
    post "/quests", ApiController, :create_quest
    get "/quests", ApiController, :list_quests
    get "/quests/:id", ApiController, :show_quest
    delete "/quests/:id", ApiController, :delete_quest
    post "/quests/:id/close", ApiController, :close_quest
    post "/quests/:id/start", ApiController, :start_quest
    get "/quests/:id/status", ApiController, :quest_status
    post "/quests/:id/plan", ApiController, :plan_quest
    get "/quests/:id/report", ApiController, :quest_report
    post "/quests/:id/merge", ApiController, :quest_merge
    get "/quests/:id/spec/:phase", ApiController, :quest_spec_show
    put "/quests/:id/spec/:phase", ApiController, :quest_spec_write
    post "/quests/:id/plan/confirm", ApiController, :confirm_plan
    post "/quests/:id/plan/reject", ApiController, :reject_plan
    post "/quests/:id/plan/revise", ApiController, :revise_plan
    get "/quests/:id/plan/candidates", ApiController, :list_plan_candidates
    post "/quests/:id/plan/select", ApiController, :select_plan_candidate

    # Jobs
    get "/jobs", ApiController, :list_jobs
    get "/jobs/:id", ApiController, :show_job
    post "/jobs/:id/reset", ApiController, :reset_job

    # Bees
    get "/bees", ApiController, :list_bees
    post "/bees/:id/stop", ApiController, :stop_bee
    post "/bees/:id/complete", ApiController, :complete_bee
    post "/bees/:id/fail", ApiController, :fail_bee

    # Combs
    post "/combs", ApiController, :add_comb
    get "/combs", ApiController, :list_combs
    get "/combs/:id", ApiController, :show_comb
    delete "/combs/:id", ApiController, :remove_comb
    post "/combs/:id/use", ApiController, :use_comb

    # Costs
    get "/costs/summary", ApiController, :costs_summary
    post "/costs/record", ApiController, :record_cost
  end
end
