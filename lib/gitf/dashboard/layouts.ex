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
          .main { padding: 1.5rem 2rem; max-width: 100%; }
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

          /* -- Link list --------------------------------------------------- */
          .link_msg-item {
            padding: 0.75rem 0;
            border-bottom: 1px solid #21262d;
          }
          .link_msg-item:last-child { border-bottom: none; }
          .link_msg-meta { font-size: 0.8rem; color: #8b949e; }
          .link_msg-subject { font-weight: 500; color: #c9d1d9; }
          .link_msg-unread .link_msg-subject { color: #f0f6fc; font-weight: 600; }

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

          /* -- Buttons ------------------------------------------------------- */
          .btn {
            padding: 0.4rem 1rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.85rem;
            font-weight: 500;
            border: 1px solid transparent;
            transition: background 0.15s, border-color 0.15s;
            display: inline-flex;
            align-items: center;
            gap: 0.35rem;
          }
          .btn-green { background: #23863633; color: #3fb950; border-color: #23863655; }
          .btn-green:hover { background: #23863655; }
          .btn-red { background: #f8514933; color: #f85149; border-color: #f8514955; }
          .btn-red:hover { background: #f8514955; }
          .btn-blue { background: #1f6feb33; color: #58a6ff; border-color: #1f6feb55; }
          .btn-blue:hover { background: #1f6feb55; }
          .btn-grey { background: #30363d; color: #8b949e; border-color: #484f58; }
          .btn-grey:hover { background: #484f58; }
          .btn-purple { background: #8b5cf633; color: #a78bfa; border-color: #8b5cf655; }
          .btn-purple:hover { background: #8b5cf655; }
          .btn-orange { background: #d2992233; color: #d29922; border-color: #d2992255; }
          .btn-orange:hover { background: #d2992255; }
          .btn:disabled { opacity: 0.5; cursor: not-allowed; }

          /* -- Forms --------------------------------------------------------- */
          .form-group { margin-bottom: 1rem; }
          .form-label { display: block; font-size: 0.85rem; color: #8b949e; margin-bottom: 0.35rem; font-weight: 500; }
          .form-input, .form-textarea, .form-select {
            width: 100%;
            background: #0d1117;
            border: 1px solid #30363d;
            border-radius: 6px;
            color: #c9d1d9;
            padding: 0.5rem 0.75rem;
            font-size: 0.9rem;
            font-family: inherit;
            transition: border-color 0.15s;
          }
          .form-input:focus, .form-textarea:focus, .form-select:focus {
            outline: none;
            border-color: #58a6ff;
          }
          .form-textarea { min-height: 100px; resize: vertical; }
          .form-select { cursor: pointer; }

          /* -- Stepper ------------------------------------------------------- */
          .stepper {
            display: flex;
            align-items: center;
            gap: 0;
            padding: 1rem 0;
            overflow-x: auto;
          }
          .step {
            display: flex;
            flex-direction: column;
            align-items: center;
            position: relative;
            flex: 1;
            min-width: 80px;
            cursor: pointer;
          }
          .step-circle {
            width: 28px;
            height: 28px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 0.7rem;
            font-weight: 700;
            z-index: 1;
          }
          .step-label { font-size: 0.7rem; margin-top: 0.35rem; color: #8b949e; text-align: center; }
          .step-done .step-circle { background: #23863655; color: #3fb950; border: 2px solid #3fb950; }
          .step-done .step-label { color: #3fb950; }
          .step-active .step-circle { background: #1f6feb55; color: #58a6ff; border: 2px solid #58a6ff; }
          .step-active .step-label { color: #58a6ff; font-weight: 600; }
          .step-future .step-circle { background: #30363d; color: #8b949e; border: 2px solid #484f58; }
          .step-line {
            flex: 1;
            height: 2px;
            background: #30363d;
            min-width: 20px;
          }
          .step-line-done { background: #3fb950; }
          .step-skipped .step-circle { background: #1c2128; color: #4b5563; border: 2px dashed #30363d; opacity: 0.5; }
          .step-skipped .step-label { color: #4b5563; font-style: italic; opacity: 0.5; }
          .step-line-skipped { background: #30363d; border-top: 2px dashed #30363d; height: 0; opacity: 0.3; }

          /* -- Action bar ---------------------------------------------------- */
          .action-bar { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 1rem; }

          /* -- Badge purple -------------------------------------------------- */
          .badge-purple { background: #8b5cf633; color: #a78bfa; }

          /* -- Loading spinner ----------------------------------------------- */
          @keyframes spin { to { transform: rotate(360deg); } }
          .loading-spinner {
            width: 24px;
            height: 24px;
            border: 3px solid #30363d;
            border-top-color: #58a6ff;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
            display: inline-block;
          }

          /* -- Tabs ---------------------------------------------------------- */
          .tab-bar { display: flex; gap: 0.25rem; border-bottom: 1px solid #30363d; margin-bottom: 1rem; }
          .tab {
            padding: 0.5rem 1rem;
            cursor: pointer;
            color: #8b949e;
            font-size: 0.85rem;
            border-bottom: 2px solid transparent;
            transition: color 0.15s, border-color 0.15s;
          }
          .tab:hover { color: #c9d1d9; }
          .tab-active { color: #58a6ff; border-bottom-color: #58a6ff; font-weight: 600; }

          /* -- Pre block ----------------------------------------------------- */
          .pre-block {
            background: #0d1117;
            border: 1px solid #30363d;
            border-radius: 6px;
            padding: 1rem;
            font-family: "SF Mono", "Fira Code", monospace;
            font-size: 0.8rem;
            line-height: 1.5;
            overflow-x: auto;
            white-space: pre-wrap;
            color: #c9d1d9;
          }

          /* -- Grid layouts -------------------------------------------------- */
          .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
          .metadata-grid {
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.35rem 1rem;
            font-size: 0.85rem;
          }
          .metadata-grid dt { color: #8b949e; font-weight: 500; }
          .metadata-grid dd { color: #c9d1d9; }

          /* -- Plan cards ---------------------------------------------------- */
          .plan-card {
            background: #161b22;
            border: 2px solid #30363d;
            border-radius: 8px;
            padding: 1.25rem;
            cursor: pointer;
            transition: border-color 0.15s;
          }
          .plan-card:hover { border-color: #58a6ff; }
          .plan-card-selected { border-color: #58a6ff; background: #1f6feb11; }
          .plan-card-title { font-weight: 600; color: #f0f6fc; margin-bottom: 0.5rem; }

          /* -- Score bar ----------------------------------------------------- */
          .score-bar { height: 6px; background: #30363d; border-radius: 3px; overflow: hidden; }
          .score-bar-fill { height: 100%; background: #3fb950; border-radius: 3px; transition: width 0.3s; }

          /* -- Nav badge ----------------------------------------------------- */
          .nav-badge {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            min-width: 18px;
            height: 18px;
            border-radius: 9px;
            font-size: 0.65rem;
            font-weight: 700;
            padding: 0 5px;
            margin-left: 4px;
          }
          .nav-badge-orange { background: #d29922; color: #0d1117; }

          /* -- Badge orange -------------------------------------------------- */
          .badge-orange { background: #d2992233; color: #d29922; }

          /* -- Timeline ------------------------------------------------------ */
          .timeline { position: relative; padding-left: 1.5rem; }
          .timeline-item {
            position: relative;
            padding: 0.5rem 0 0.5rem 1rem;
            border-left: 2px solid #30363d;
          }
          .timeline-item:last-child { border-left-color: transparent; }
          .timeline-item-stuck { border-left-color: #f85149; }
          .timeline-item-stuck .timeline-dot { background: #f85149; box-shadow: 0 0 6px #f8514966; }
          .timeline-dot {
            position: absolute;
            left: -7px;
            top: 0.75rem;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: #58a6ff;
            border: 2px solid #161b22;
          }
          .timeline-content { padding-left: 0.5rem; }

          /* -- Retry chain --------------------------------------------------- */
          .retry-chain {
            display: flex;
            align-items: center;
            gap: 0.25rem;
            flex-wrap: wrap;
            padding: 0.5rem 0;
          }
          .retry-node {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 0.2rem;
            background: #0d1117;
            border: 1px solid #30363d;
            border-radius: 6px;
            padding: 0.35rem 0.5rem;
          }
          .retry-node-current { border-color: #f85149; }
          .retry-arrow { color: #484f58; font-size: 0.9rem; padding: 0 0.15rem; }

          /* -- Card value red ------------------------------------------------- */
          .card-value.red { color: #f85149; }

          /* -- Design viewer ------------------------------------------------- */
          .design-layout { display: grid; grid-template-columns: 1fr 300px; gap: 1rem; }
          .tab-minimal.tab-active { border-bottom-color: #58a6ff; }
          .tab-normal.tab-active { border-bottom-color: #3fb950; }
          .tab-complex.tab-active { border-bottom-color: #a78bfa; }
          .design-winner { border: 2px solid #d29922; background: rgba(210,153,34,0.07); border-radius: 8px; padding: 1rem; position: relative; }
          .design-winner::before { content: "AI PICK"; position: absolute; top: -10px; right: 12px; background: #d29922; color: #0d1117; font-size: 0.65rem; font-weight: 700; padding: 1px 8px; border-radius: 4px; }
          .section-header { display: flex; align-items: center; gap: 0.5rem; cursor: pointer; padding: 0.6rem 0; border-bottom: 1px solid #21262d; color: #f0f6fc; font-weight: 600; font-size: 0.9rem; user-select: none; }
          .section-header:hover { color: #58a6ff; }
          .section-chevron { transition: transform 0.15s; display: inline-block; }
          .section-chevron.open { transform: rotate(90deg); }
          .coverage-item { display: flex; align-items: center; gap: 0.4rem; padding: 0.25rem 0; font-size: 0.85rem; }
          .coverage-ok { color: #3fb950; }
          .coverage-gap { color: #f85149; }
          .issue-item { padding: 0.4rem 0 0.4rem 0.6rem; margin: 0.25rem 0; font-size: 0.85rem; }
          .issue-high { border-left: 3px solid #f85149; }
          .issue-medium { border-left: 3px solid #d29922; }
          .issue-low { border-left: 3px solid #8b949e; }
          .strategy-card { border: 1px solid #30363d; border-radius: 8px; padding: 1rem; background: #161b22; }
          .strategy-card.selected { border-color: #d29922; }
          .override-btn { padding: 0.4rem 1rem; border-radius: 6px; border: 1px solid #30363d; background: #21262d; color: #c9d1d9; cursor: pointer; font-size: 0.85rem; }
          .override-btn:hover { border-color: #58a6ff; }
          .override-btn.active { border-color: #d29922; background: rgba(210,153,34,0.15); color: #d29922; }
          .component-card { border: 1px solid #21262d; border-radius: 6px; padding: 0.75rem; margin: 0.5rem 0; background: #0d1117; }
          .file-tag { display: inline-block; background: #21262d; padding: 0.15rem 0.5rem; border-radius: 4px; font-family: monospace; font-size: 0.8rem; margin: 0.15rem; }

          /* -- Plan checklist ------------------------------------------------ */
          .checklist-item { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.75rem; border-bottom: 1px solid #21262d; cursor: pointer; transition: background 0.15s; }
          .checklist-item:hover { background: #1c2128; }
          .checklist-item-done { opacity: 0.7; }
          .status-icon { font-size: 1rem; min-width: 1.2rem; text-align: center; }
          .status-icon-pending { color: #8b949e; }
          .status-icon-running { color: #58a6ff; }
          .status-icon-done { color: #3fb950; }
          .status-icon-failed { color: #f85149; }
          .status-icon-blocked { color: #d29922; }
          .criteria-item { display: flex; align-items: flex-start; gap: 0.4rem; padding: 0.2rem 0; font-size: 0.85rem; color: #8b949e; }
          .ghost-tag { display: inline-flex; align-items: center; gap: 0.25rem; background: rgba(31,111,235,0.13); padding: 0.1rem 0.5rem; border-radius: 10px; font-size: 0.75rem; color: #58a6ff; }

          /* Ghost model badges — provider color + tier icon, sci-fi glow */
          .model-badge { display: inline-flex; align-items: center; gap: 0.25rem; padding: 0.15rem 0.5rem; border-radius: 4px; font-size: 0.7rem; font-weight: 600; letter-spacing: 0.03em; border: 1px solid; font-family: monospace; white-space: nowrap; }
          .model-google { color: #58a6ff; border-color: #1f6feb55; background: linear-gradient(135deg, #0d2a5c22, #0d2a5c44); text-shadow: 0 0 8px #58a6ff66; }
          .model-anthropic { color: #f07070; border-color: #da363655; background: linear-gradient(135deg, #3d1a1a22, #3d1a1a44); text-shadow: 0 0 8px #f0707066; }
          .model-openai { color: #3fb950; border-color: #23863655; background: linear-gradient(135deg, #0d2d1622, #0d2d1644); text-shadow: 0 0 8px #3fb95066; }
          .model-ollama { color: #3fb950; border-color: #23863655; background: linear-gradient(135deg, #0d2d1622, #0d2d1644); text-shadow: 0 0 8px #3fb95066; }
          .model-bedrock { color: #f0983e; border-color: #d2870055; background: linear-gradient(135deg, #3d2a0022, #3d2a0044); text-shadow: 0 0 8px #f0983e66; }
          .model-unknown { color: #8b949e; border-color: #30363d55; background: linear-gradient(135deg, #16161622, #16161644); text-shadow: 0 0 6px #8b949e44; }
          .group-progress { width: 60px; height: 4px; background: #30363d; border-radius: 2px; overflow: hidden; margin-left: auto; }
          .group-progress-fill { height: 100%; background: #3fb950; border-radius: 2px; transition: width 0.5s ease; }
          .plan-progress { height: 8px; background: #30363d; border-radius: 4px; overflow: hidden; margin-top: 0.5rem; }
          .plan-progress-fill { height: 100%; border-radius: 4px; transition: width 0.5s ease; background: linear-gradient(90deg, #3fb950, #58a6ff); }
          @keyframes check-in { from { transform: scale(0.5); opacity: 0; } to { transform: scale(1); opacity: 1; } }
          .status-just-done .status-icon { animation: check-in 0.3s ease-out; }

          /* -- Responsive ---------------------------------------------------- */
          @media (max-width: 1024px) { .design-layout { grid-template-columns: 1fr; } }
          @media (max-width: 768px) {
            .nav { flex-direction: column; height: auto; padding: 0.75rem; gap: 0.5rem; }
            .cards { grid-template-columns: 1fr 1fr; }
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/assets/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view.min.js"></script>
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

end
