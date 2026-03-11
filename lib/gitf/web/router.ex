defmodule GiTF.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GiTF.Web.Layout, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api_public do
    plug :accepts, ["json"]
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :require_local_or_api_key
  end

  scope "/", GiTF.Web do
    pipe_through :browser

    live "/", Live.Dashboard
  end

  # Health endpoint — no auth required (monitoring)
  scope "/api/v1", GiTF.Web do
    pipe_through :api_public
    get "/health", ApiController, :health
  end

  scope "/api/v1", GiTF.Web do
    pipe_through :api

    # Quests
    post "/quests", ApiController, :create_quest
    get "/quests", ApiController, :list_quests
    get "/quests/:id", ApiController, :show_quest
    delete "/quests/:id", ApiController, :delete_quest
    post "/quests/:id/kill", ApiController, :kill_quest
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
    delete "/jobs/:id", ApiController, :kill_job

    # Bees
    get "/ghosts", ApiController, :list_bees
    post "/ghosts/:id/stop", ApiController, :stop_ghost
    post "/ghosts/:id/complete", ApiController, :complete_bee
    post "/ghosts/:id/fail", ApiController, :fail_bee

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

  # Restrict API to localhost unless a valid API key is provided.
  # The API key is read from the section config file (api_key field).
  defp require_local_or_api_key(conn, _opts) do
    remote_ip = conn.remote_ip

    if local_ip?(remote_ip) do
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

  defp valid_api_key?(key) do
    case GiTF.Config.get(:api_key) do
      nil -> false
      configured_key -> Plug.Crypto.secure_compare(key, configured_key)
    end
  end
end
