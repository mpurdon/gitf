defmodule GiTF.Dashboard.Layouts do
  @moduledoc """
  Layout components for the GiTF dashboard.

  All CSS is inline -- no external stylesheets, no asset pipeline, no
  esbuild, no Tailwind. The LiveView JavaScript client is loaded from
  a CDN so there are zero Node.js dependencies.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  @doc "Root HTML layout wrapping every page."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>GiTF Dashboard</title>
        <style>
          /* -- Reset & Base -------------------------------------------------- */
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          html { font-size: 15px; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                         "Helvetica Neue", Arial, sans-serif;
            background: #0d1117;
            color: #c9d1d9;
            line-height: 1.6;
            min-height: 100vh;
          }
          a { color: #58a6ff; text-decoration: none; }
          a:hover { text-decoration: underline; }

          /* -- Navigation ---------------------------------------------------- */
          .nav {
            background: #161b22;
            border-bottom: 1px solid #30363d;
            padding: 0 1.5rem;
            display: flex;
            align-items: center;
            height: 52px;
          }
          .nav-brand {
            font-weight: 700;
            font-size: 1.15rem;
            color: #f0f6fc;
            margin-right: 2rem;
            letter-spacing: 0.5px;
          }
          .nav-brand span { color: #d29922; }
          .nav-links { display: flex; gap: 0.25rem; }
          .nav-links a {
            padding: 0.4rem 0.85rem;
            border-radius: 6px;
            color: #8b949e;
            font-size: 0.9rem;
            transition: background 0.15s, color 0.15s;
          }
          .nav-links a:hover { background: #1f2937; color: #c9d1d9; text-decoration: none; }
          .nav-links a.active { background: #1f6feb33; color: #58a6ff; }

          /* -- Main content -------------------------------------------------- */
          .main { padding: 1.5rem; max-width: 1200px; margin: 0 auto; }
          .page-title {
            font-size: 1.5rem;
            font-weight: 600;
            color: #f0f6fc;
            margin-bottom: 1.25rem;
          }

          /* -- Cards & Panels ------------------------------------------------ */
          .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
          .card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 8px;
            padding: 1.25rem;
          }
          .card-label { font-size: 0.8rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.35rem; }
          .card-value { font-size: 1.75rem; font-weight: 700; color: #f0f6fc; }
          .card-value.green { color: #3fb950; }
          .card-value.blue { color: #58a6ff; }
          .card-value.yellow { color: #d29922; }

          .panel {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 8px;
            padding: 1.25rem;
            margin-bottom: 1.5rem;
          }
          .panel-title {
            font-size: 1rem;
            font-weight: 600;
            color: #f0f6fc;
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 1px solid #30363d;
          }

          /* -- Tables -------------------------------------------------------- */
          table { width: 100%; border-collapse: collapse; }
          th {
            text-align: left;
            font-size: 0.8rem;
            color: #8b949e;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            padding: 0.6rem 0.75rem;
            border-bottom: 1px solid #30363d;
          }
          td {
            padding: 0.6rem 0.75rem;
            border-bottom: 1px solid #21262d;
            font-size: 0.9rem;
          }
          tr:hover td { background: #1c2128; }

          /* -- Status badges ------------------------------------------------- */
          .badge {
            display: inline-block;
            padding: 0.15rem 0.55rem;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.03em;
          }
          .badge-green  { background: #23863633; color: #3fb950; }
          .badge-blue   { background: #1f6feb33; color: #58a6ff; }
          .badge-grey   { background: #30363d; color: #8b949e; }
          .badge-red    { background: #f8514933; color: #f85149; }
          .badge-yellow { background: #d2992233; color: #d29922; }

          /* -- Waggle list --------------------------------------------------- */
          .waggle-item {
            padding: 0.75rem 0;
            border-bottom: 1px solid #21262d;
          }
          .waggle-item:last-child { border-bottom: none; }
          .waggle-meta { font-size: 0.8rem; color: #8b949e; }
          .waggle-subject { font-weight: 500; color: #c9d1d9; }
          .waggle-unread .waggle-subject { color: #f0f6fc; font-weight: 600; }

          /* -- Pulse animation for working ghosts ------------------------------ */
          @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
          .pulse { animation: pulse 2s ease-in-out infinite; }

          /* -- Empty state --------------------------------------------------- */
          .empty { color: #8b949e; font-style: italic; padding: 1.5rem 0; text-align: center; }

          /* -- Detail toggle ------------------------------------------------- */
          .detail-toggle { cursor: pointer; user-select: none; }
          .detail-toggle:hover { color: #58a6ff; }
          .detail-content { padding: 0.5rem 0 0.5rem 1.5rem; }

          /* -- Flash messages ------------------------------------------------ */
          .flash-info { background: #1f6feb33; border: 1px solid #1f6feb55; color: #58a6ff; padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; }
          .flash-error { background: #f8514933; border: 1px solid #f8514955; color: #f85149; padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; }

          /* -- Cost bar ------------------------------------------------------ */
          .cost-bar { height: 6px; background: #30363d; border-radius: 3px; margin-top: 0.25rem; overflow: hidden; }
          .cost-bar-fill { height: 100%; background: #58a6ff; border-radius: 3px; transition: width 0.3s; }

          /* -- Responsive ---------------------------------------------------- */
          @media (max-width: 768px) {
            .nav { flex-direction: column; height: auto; padding: 0.75rem; gap: 0.5rem; }
            .cards { grid-template-columns: 1fr 1fr; }
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.4/priv/static/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end

  @doc "App layout rendered inside the root for each LiveView."
  def app(assigns) do
    ~H"""
    <nav class="nav">
      <div class="nav-brand">The <span>GiTF</span></div>
      <div class="nav-links">
        <a href="/" class={if @current_path == "/", do: "active"}>Overview</a>
        <a href="/quests" class={if @current_path == "/quests", do: "active"}>Quests</a>
        <a href="/ghosts" class={if @current_path == "/ghosts", do: "active"}>Bees</a>
        <a href="/costs" class={if @current_path == "/costs", do: "active"}>Costs</a>
        <a href="/waggles" class={if @current_path == "/waggles", do: "active"}>Waggles</a>
      </div>
    </nav>
    <main class="main">
      <.flash_group flash={@flash} />
      {@inner_content}
    </main>
    """
  end

  defp flash_group(assigns) do
    ~H"""
    <div :if={Phoenix.Flash.get(@flash, :info)} class="flash-info">
      {Phoenix.Flash.get(@flash, :info)}
    </div>
    <div :if={Phoenix.Flash.get(@flash, :error)} class="flash-error">
      {Phoenix.Flash.get(@flash, :error)}
    </div>
    """
  end
end
