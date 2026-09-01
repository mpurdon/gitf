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
          /* Control-surface tokens (GiTF Control Surface plan §06) — the
             factory is dark-first; pages still carry inline hexes from the
             old palette, swept page by page. */
          :root{
            --ground:#14181E; --panel:#1C2129; --panel-2:#20262F;
            --line:#2A313B; --line-2:#252C35; --line-strong:#3A4452;
            --text:#E9EDF2; --text-2:#B4BDC9; --muted:#8B95A5;
            --accent:#4C9AFF; --accent-ink:#0E1218; --accent-soft:#1B2C45;
            --rail:#0D1218; --rail-text:#8B98A9; --rail-on:#FFFFFF; --rail-active:rgba(255,255,255,.07);
            --ok:#43C383; --ok-bg:#15291F; --warn:#E0A82E; --warn-bg:#2E2513;
            --crit:#EA6A62; --crit-bg:#321B1B; --recon:var(--recon); --recon-bg:#241E38;
            --off:#6B7684; --off-bg:#232933;
            --shadow:0 1px 2px rgba(0,0,0,.3);
            --mono:"JetBrains Mono","SF Mono","Fira Code",ui-monospace,monospace;
          }
          /* -- Reset & Base -------------------------------------------------- */
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          html { font-size: 15px; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                         "Helvetica Neue", Arial, sans-serif;
            background: var(--ground);
            color: var(--text-2);
            line-height: 1.6;
            min-height: 100vh;
          }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }

          /* -- Navigation: rail + secondary bar ------------------------------ */
          .layout { display: grid; grid-template-columns: 76px minmax(0,1fr); min-height: 100vh; }
          .rail {
            background: var(--rail); color: var(--rail-text);
            display: flex; flex-direction: column; align-items: center;
            padding: 12px 0; gap: 2px; position: sticky; top: 0; height: 100vh; z-index: 20;
          }
          .rail-logo {
            width: 38px; height: 38px; border-radius: 10px; background: var(--accent);
            color: #fff; display: grid; place-items: center; margin-bottom: 12px;
            font-weight: 700; font-size: 0.95rem; position: relative; text-decoration: none;
          }
          .rail-logo:hover { text-decoration: none; }
          .rail a.rail-item, .rail button.rail-item {
            width: 62px; padding: 8px 0 6px; border-radius: 10px; border: none; background: none;
            display: flex; flex-direction: column; align-items: center; gap: 3px;
            font-size: 0.62rem; letter-spacing: 0.02em; color: var(--rail-text);
            cursor: pointer; text-decoration: none;
          }
          .rail a.rail-item:hover, .rail button.rail-item:hover { color: var(--rail-on); text-decoration: none; }
          .rail a.rail-item.active { background: var(--rail-active); color: var(--rail-on); }
          .rail-ico { width: 20px; height: 20px; stroke: currentColor; fill: none; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
          .rail-badge-anchor { position: relative; }
          .rail-count {
            position: absolute; top: -5px; right: -10px; background: var(--warn); color: #fff;
            font-family: var(--mono); font-size: 0.56rem; line-height: 1; padding: 2px 4px; border-radius: 8px;
          }
          .rail-spacer { flex: 1; }
          .rail-version { font-size: 0.58rem; color: var(--rail-text); opacity: 0.7; padding: 6px 0; }
          .rail-stop { color: var(--crit); }
          .rail-stop-confirm { display: flex; flex-direction: column; gap: 4px; align-items: center; font-size: 0.6rem; color: var(--rail-on); padding: 4px 0; }
          .rail-stop-confirm button { border: 1px solid var(--line-strong); border-radius: 6px; background: none; color: inherit; font-size: 0.62rem; padding: 2px 8px; cursor: pointer; }
          .rail-stop-confirm button.yes { border-color: var(--crit); color: var(--crit); }
          .subnav {
            display: flex; align-items: center; gap: 2px; flex-wrap: wrap;
            padding: 10px 2rem 0; position: sticky; top: 0; background: var(--ground); z-index: 10;
          }
          .subnav a {
            padding: 0.35rem 0.7rem; border-radius: 7px; color: var(--muted);
            font-size: 0.82rem; font-weight: 600; text-decoration: none;
          }
          .subnav a:hover { background: var(--panel-2); color: var(--text-2); text-decoration: none; }
          .subnav a.active { background: var(--accent-soft); color: var(--accent); }
          .subnav .nav-badge { margin-left: 0.3rem; }
          .nav-badge {
            display: inline-block; font-family: var(--mono); font-size: 0.62rem;
            padding: 1px 5px; border-radius: 8px; vertical-align: 1px;
          }
          .nav-badge-orange { background: var(--warn-bg); color: var(--warn); }
          .nav-activity {
            display: inline-block; width: 7px; height: 7px; border-radius: 50%;
            position: absolute; top: -2px; right: -2px;
          }
          /* -- Main content -------------------------------------------------- */
          .main { padding: 1.5rem 2rem; max-width: 100%; position: relative; }
          .page-title {
            font-size: 1.5rem;
            font-weight: 600;
            color: var(--text);
            margin-bottom: 1.25rem;
          }

          /* -- Cards & Panels ------------------------------------------------ */
          .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
          .card {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 8px;
            padding: 1.25rem;
          }
          .card-label { font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.35rem; }
          .card-value { font-size: 1.75rem; font-weight: 700; color: var(--text); }
          .card-value.green { color: var(--ok); }
          .card-value.blue { color: var(--accent); }
          .card-value.yellow { color: var(--warn); }

          .panel {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 8px;
            padding: 1.25rem;
            margin-bottom: 1.5rem;
          }
          .panel-title {
            font-size: 1rem;
            font-weight: 600;
            color: var(--text);
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 1px solid var(--line);
          }

          /* -- Tables -------------------------------------------------------- */
          table { width: 100%; border-collapse: collapse; }
          th {
            text-align: left;
            font-size: 0.8rem;
            color: var(--muted);
            text-transform: uppercase;
            letter-spacing: 0.04em;
            padding: 0.6rem 0.75rem;
            border-bottom: 1px solid var(--line);
          }
          td {
            padding: 0.6rem 0.75rem;
            border-bottom: 1px solid var(--line-2);
            font-size: 0.9rem;
          }
          tr:hover td { background: var(--panel-2); }

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
          .badge-green  { background: var(--ok)33; color: var(--ok); }
          .badge-blue   { background: var(--accent-soft); color: var(--accent); }
          .badge-grey   { background: var(--line); color: var(--muted); }
          .badge-red    { background: var(--crit)33; color: var(--crit); }
          .badge-yellow { background: var(--warn)33; color: var(--warn); }

          /* -- Report metric cards ------------------------------------------ */
          .report-metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
            gap: 0.6rem;
            margin-top: 0.5rem;
          }
          .metric-card {
            background: var(--ground);
            border: 1px solid var(--line);
            border-radius: 6px;
            padding: 0.6rem 0.8rem;
          }
          .metric-label { font-size: 0.7rem; color: var(--muted); margin-bottom: 0.15rem; }
          .metric-value { font-size: 1rem; font-weight: 600; color: var(--text-2); }

          /* -- Link list --------------------------------------------------- */
          .link_msg-item {
            padding: 0.75rem 0;
            border-bottom: 1px solid var(--line-2);
          }
          .link_msg-item:last-child { border-bottom: none; }
          .link_msg-meta { font-size: 0.8rem; color: var(--muted); }
          .link_msg-subject { font-weight: 500; color: var(--text-2); }
          .link_msg-unread .link_msg-subject { color: var(--text); font-weight: 600; }

          /* -- Pulse animation for working ghosts ------------------------------ */
          @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
          .pulse { animation: pulse 2s ease-in-out infinite; }

          /* -- Empty state --------------------------------------------------- */
          .empty { color: var(--muted); font-style: italic; padding: 1.5rem 0; text-align: center; }

          /* -- Detail toggle ------------------------------------------------- */
          .detail-toggle { cursor: pointer; user-select: none; }
          .detail-toggle:hover { color: var(--accent); }
          .detail-content { padding: 0.5rem 0 0.5rem 1.5rem; }

          /* -- Flash messages ------------------------------------------------ */
          .flash-info { background: var(--accent-soft); border: 1px solid var(--accent)55; color: var(--accent); padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; }
          .flash-error { background: var(--crit)33; border: 1px solid var(--crit)55; color: var(--crit); padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; }

          /* -- Cost bar ------------------------------------------------------ */
          .cost-bar { height: 6px; background: var(--line); border-radius: 3px; margin-top: 0.25rem; overflow: hidden; }
          .cost-bar-fill { height: 100%; background: var(--accent); border-radius: 3px; transition: width 0.3s; }

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
          .btn-green { background: var(--ok)33; color: var(--ok); border-color: var(--ok)55; }
          .btn-green:hover { background: var(--ok)55; }
          /* Panic control in the nav. Quiet until hovered — it should be
             findable at a glance without competing with navigation. */
          .nav-stop { background: var(--crit)22; color: var(--crit); border: 1px solid var(--crit)55; border-radius: 4px; padding: 0.1rem 0.45rem; font-size: 0.7rem; font-weight: 600; cursor: pointer; margin-left: 0.5rem; }
          .nav-stop:hover { background: var(--crit); color: var(--ground); }
          .nav-stop-cancel { background: none; color: var(--muted); border: 1px solid var(--line); border-radius: 4px; padding: 0.1rem 0.45rem; font-size: 0.7rem; cursor: pointer; margin-left: 0.25rem; }
          .nav-stop-confirm { font-size: 0.7rem; color: var(--crit); margin-left: 0.5rem; display: inline-flex; align-items: center; }
          .nav-stop-result { font-size: 0.7rem; color: var(--muted); margin-left: 0.5rem; }
          .btn-red { background: var(--crit)33; color: var(--crit); border-color: var(--crit)55; }
          .btn-red:hover { background: var(--crit)55; }
          .btn-blue { background: var(--accent-soft); color: var(--accent); border-color: var(--accent)55; }
          .btn-blue:hover { background: var(--accent)55; }
          .btn-grey { background: var(--line); color: var(--muted); border-color: var(--line-strong); }
          .btn-grey:hover { background: var(--line-strong); }
          .btn-purple { background: var(--recon)33; color: var(--recon); border-color: var(--recon)55; }
          .btn-purple:hover { background: var(--recon)55; }
          .btn-orange { background: var(--warn)33; color: var(--warn); border-color: var(--warn)55; }
          .btn-orange:hover { background: var(--warn)55; }
          .btn:disabled { opacity: 0.5; cursor: not-allowed; }

          /* -- Forms --------------------------------------------------------- */
          .form-group { margin-bottom: 1rem; }
          .form-label { display: block; font-size: 0.85rem; color: var(--muted); margin-bottom: 0.35rem; font-weight: 500; }
          .form-input, .form-textarea, .form-select {
            width: 100%;
            background: var(--ground);
            border: 1px solid var(--line);
            border-radius: 6px;
            color: var(--text-2);
            padding: 0.5rem 0.75rem;
            font-size: 0.9rem;
            font-family: inherit;
            transition: border-color 0.15s;
          }
          .form-input:focus, .form-textarea:focus, .form-select:focus {
            outline: none;
            border-color: var(--accent);
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
          .step-label { font-size: 0.7rem; margin-top: 0.35rem; color: var(--muted); text-align: center; }
          .step-done .step-circle { background: var(--ok)55; color: var(--ok); border: 2px solid var(--ok); }
          .step-done .step-label { color: var(--ok); }
          .step-active .step-circle { background: var(--accent)55; color: var(--accent); border: 2px solid var(--accent); }
          .step-active .step-label { color: var(--accent); font-weight: 600; }
          .step-future .step-circle { background: var(--line); color: var(--muted); border: 2px solid var(--line-strong); }
          .step-line {
            flex: 1;
            height: 2px;
            background: var(--line);
            min-width: 20px;
          }
          .step-line-done { background: var(--ok); }
          .step-failed .step-circle { background: var(--crit)22; color: var(--crit); border: 2px solid var(--crit); }
          .step-failed .step-label { color: var(--crit); font-weight: 600; }
          .step-skipped .step-circle { background: var(--panel-2); color: var(--muted); border: 2px dashed var(--line); opacity: 0.5; }
          .step-skipped .step-label { color: var(--muted); font-style: italic; opacity: 0.5; }
          .step-line-skipped { background: var(--line); border-top: 2px dashed var(--line); height: 0; opacity: 0.3; }

          /* -- Action bar ---------------------------------------------------- */
          .action-bar { display: flex; justify-content: flex-end; gap: 0.5rem; margin-top: 1rem; }

          /* -- Badge purple -------------------------------------------------- */
          .badge-purple { background: var(--recon)33; color: var(--recon); }

          /* -- Loading spinner ----------------------------------------------- */
          @keyframes spin { to { transform: rotate(360deg); } }
          .loading-spinner {
            width: 24px;
            height: 24px;
            border: 3px solid var(--line);
            border-top-color: var(--accent);
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
            display: inline-block;
          }

          /* -- Tabs ---------------------------------------------------------- */
          .tab-bar { display: flex; gap: 0.25rem; border-bottom: 1px solid var(--line); margin-bottom: 1rem; }
          .tab {
            padding: 0.5rem 1rem;
            cursor: pointer;
            color: var(--muted);
            font-size: 0.85rem;
            border-bottom: 2px solid transparent;
            transition: color 0.15s, border-color 0.15s;
          }
          .tab:hover { color: var(--text-2); }
          .tab-active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }

          /* -- Pre block ----------------------------------------------------- */
          .pre-block {
            background: var(--ground);
            border: 1px solid var(--line);
            border-radius: 6px;
            padding: 1rem;
            font-family: "SF Mono", "Fira Code", monospace;
            font-size: 0.8rem;
            line-height: 1.5;
            overflow-x: auto;
            white-space: pre-wrap;
            color: var(--text-2);
          }

          /* -- Grid layouts -------------------------------------------------- */
          .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
          .metadata-grid {
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.35rem 1rem;
            font-size: 0.85rem;
          }
          .metadata-grid dt { color: var(--muted); font-weight: 500; }
          .metadata-grid dd { color: var(--text-2); }

          /* -- Plan cards ---------------------------------------------------- */
          .plan-card {
            background: var(--panel);
            border: 2px solid var(--line);
            border-radius: 8px;
            padding: 1.25rem;
            cursor: pointer;
            transition: border-color 0.15s;
          }
          .plan-card:hover { border-color: var(--accent); }
          .plan-card-selected { border-color: var(--accent); background: var(--accent)11; }
          .plan-card-title { font-weight: 600; color: var(--text); margin-bottom: 0.5rem; }

          /* -- Score bar ----------------------------------------------------- */
          .score-bar { height: 6px; background: var(--line); border-radius: 3px; overflow: hidden; }
          .score-bar-fill { height: 100%; background: var(--ok); border-radius: 3px; transition: width 0.3s; }

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
          .nav-badge-orange { background: var(--warn); color: var(--ground); }

          /* -- Badge orange -------------------------------------------------- */
          .badge-orange { background: var(--warn)33; color: var(--warn); }

          /* -- Toast notifications -------------------------------------------- */
          .toast-container {
            position: fixed;
            bottom: 1rem;
            right: 1rem;
            z-index: 9999;
            display: flex;
            flex-direction: column-reverse;
            gap: 0.5rem;
            max-width: 380px;
          }
          .toast {
            padding: 0.65rem 1rem;
            border-radius: 6px;
            font-size: 0.8rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
            animation: toast-in 0.3s ease-out;
            border: 1px solid var(--line);
            background: var(--panel);
            color: var(--text-2);
            box-shadow: 0 4px 12px rgba(0,0,0,0.4);
          }
          .toast-success { border-left: 3px solid var(--ok); }
          .toast-warning { border-left: 3px solid var(--warn); }
          .toast-error { border-left: 3px solid var(--crit); }
          .toast-info { border-left: 3px solid var(--accent); }
          @keyframes toast-in {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
          }

          /* -- Sortable columns ----------------------------------------------- */
          th.sortable { cursor: pointer; user-select: none; }
          th.sortable:hover { color: var(--accent); }

          /* -- Timeline ------------------------------------------------------ */
          .timeline { position: relative; padding-left: 1.5rem; }
          .timeline-item {
            position: relative;
            padding: 0.5rem 0 0.5rem 1rem;
            border-left: 2px solid var(--line);
          }
          .timeline-item:last-child { border-left-color: transparent; }
          .timeline-item-stuck { border-left-color: var(--crit); }
          .timeline-item-stuck .timeline-dot { background: var(--crit); box-shadow: 0 0 6px var(--crit)66; }
          .timeline-dot {
            position: absolute;
            left: -7px;
            top: 0.75rem;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: var(--accent);
            border: 2px solid var(--panel);
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
            background: var(--ground);
            border: 1px solid var(--line);
            border-radius: 6px;
            padding: 0.35rem 0.5rem;
          }
          .retry-node-current { border-color: var(--crit); }
          .retry-arrow { color: var(--line-strong); font-size: 0.9rem; padding: 0 0.15rem; }

          /* -- Card value red ------------------------------------------------- */
          .card-value.red { color: var(--crit); }

          /* -- Design viewer ------------------------------------------------- */
          .design-layout { display: grid; grid-template-columns: 1fr 300px; gap: 1rem; }
          .review-split { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 1rem; }
          .tab-minimal.tab-active { border-bottom-color: var(--accent); }
          .tab-normal.tab-active { border-bottom-color: var(--ok); }
          .tab-complex.tab-active { border-bottom-color: var(--recon); }
          .design-winner { border: 2px solid var(--warn); background: rgba(210,153,34,0.07); border-radius: 8px; padding: 1rem; position: relative; }
          .design-winner::before { content: "AI PICK"; position: absolute; top: -10px; right: 12px; background: var(--warn); color: var(--ground); font-size: 0.65rem; font-weight: 700; padding: 1px 8px; border-radius: 4px; }
          .section-header { display: flex; align-items: center; gap: 0.5rem; cursor: pointer; padding: 0.6rem 0; border-bottom: 1px solid var(--line-2); color: var(--text); font-weight: 600; font-size: 0.9rem; user-select: none; }
          .section-header:hover { color: var(--accent); }
          .section-chevron { transition: transform 0.15s; display: inline-block; }
          .section-chevron.open { transform: rotate(90deg); }
          /* Requirement text sits beside the id, so rows wrap rather than
             clip: align to the first line, not the vertical centre. */
          .coverage-item { display: flex; align-items: baseline; gap: 0.4rem; padding: 0.25rem 0; font-size: 0.85rem; line-height: 1.45; }
          .coverage-item > span:last-child { min-width: 0; }
          .coverage-ok { color: var(--ok); }
          .coverage-gap { color: var(--crit); }
          .issue-item { padding: 0.4rem 0 0.4rem 0.6rem; margin: 0.25rem 0; font-size: 0.85rem; }
          .issue-high { border-left: 3px solid var(--crit); }
          .issue-medium { border-left: 3px solid var(--warn); }
          .issue-low { border-left: 3px solid var(--muted); }
          .strategy-card { border: 1px solid var(--line); border-radius: 8px; padding: 1rem; background: var(--panel); }
          .strategy-card.selected { border-color: var(--warn); }
          .override-btn { padding: 0.4rem 1rem; border-radius: 6px; border: 1px solid var(--line); background: var(--line-2); color: var(--text-2); cursor: pointer; font-size: 0.85rem; }
          .override-btn:hover { border-color: var(--accent); }
          .override-btn.active { border-color: var(--warn); background: rgba(210,153,34,0.15); color: var(--warn); }
          .component-card { border: 1px solid var(--line-2); border-radius: 6px; padding: 0.75rem; margin: 0.5rem 0; background: var(--ground); }
          .file-tag { display: inline-block; background: var(--line-2); padding: 0.15rem 0.5rem; border-radius: 4px; font-family: monospace; font-size: 0.8rem; margin: 0.15rem; }

          /* -- Plan checklist ------------------------------------------------ */
          .checklist-item { display: flex; align-items: center; gap: 0.6rem; padding: 0.65rem 0.85rem; border-bottom: 1px solid var(--line-2); cursor: pointer; transition: background 0.15s; }
          .checklist-item:hover { background: var(--panel-2); }
          .checklist-item-done { opacity: 0.6; }
          .checklist-item-running { border-left: 3px solid var(--accent); background: rgba(31,111,235,0.04); }
          .checklist-item-failed { border-left: 3px solid var(--crit); background: rgba(248,81,73,0.04); }
          .checklist-item-blocked { border-left: 3px solid var(--warn); background: rgba(210,153,34,0.04); }
          .status-icon { font-size: 1rem; min-width: 1.2rem; text-align: center; }
          .status-icon-pending { color: var(--muted); }
          .status-icon-running { color: var(--accent); }
          .status-icon-done { color: var(--ok); }
          .status-icon-failed { color: var(--crit); }
          .status-icon-blocked { color: var(--warn); }
          .criteria-item { display: flex; align-items: flex-start; gap: 0.4rem; padding: 0.2rem 0; font-size: 0.85rem; color: var(--muted); }
          .ghost-tag { display: inline-flex; align-items: center; gap: 0.25rem; background: rgba(31,111,235,0.13); padding: 0.1rem 0.5rem; border-radius: 10px; font-size: 0.75rem; color: var(--accent); }

          /* -- Plan page layout ---------------------------------------------- */
          .plan-stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 0.75rem; margin-bottom: 1.25rem; }
          .plan-stat { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 0.75rem 1rem; text-align: center; }
          .plan-stat-value { font-size: 1.5rem; font-weight: 700; color: var(--text); }
          .plan-stat-label { font-size: 0.7rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; margin-top: 0.15rem; }
          .plan-group { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; margin-bottom: 1rem; overflow: hidden; }
          .plan-group-header { display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem 1rem; cursor: pointer; user-select: none; border-bottom: 1px solid var(--line-2); transition: background 0.15s; }
          .plan-group-header:hover { background: var(--panel-2); }
          .plan-group-title { font-weight: 600; font-size: 0.9rem; color: var(--text); }
          .plan-group-count { font-size: 0.8rem; color: var(--muted); font-weight: 400; }
          .plan-group-progress { width: 80px; height: 5px; background: var(--line); border-radius: 3px; overflow: hidden; margin-left: auto; }
          .plan-group-progress-fill { height: 100%; background: var(--ok); border-radius: 3px; transition: width 0.5s ease; }
          .plan-group-pct { font-size: 0.75rem; color: var(--muted); font-family: monospace; min-width: 2.5rem; text-align: right; }
          .plan-detail { padding: 0.85rem 1rem 1rem 2.75rem; border-bottom: 1px solid var(--line-2); background: var(--ground); }
          .plan-detail-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 1.25rem; }
          @media (max-width: 768px) { .plan-detail-grid { grid-template-columns: 1fr; } }
          .plan-file-item { font-family: "SF Mono", "Fira Code", monospace; font-size: 0.8rem; color: var(--muted); padding: 0.2rem 0; border-left: 2px solid var(--line); padding-left: 0.5rem; margin: 0.15rem 0; }
          .plan-detail-section { margin-bottom: 0.75rem; }
          .plan-detail-section:last-child { margin-bottom: 0; }
          .plan-detail-heading { font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; margin-bottom: 0.4rem; border-bottom: 1px solid var(--line-2); padding-bottom: 0.25rem; }

          /* -- Plan description formatting ---------------------------------- */
          .plan-desc { font-size: 0.85rem; color: var(--text-2); margin-bottom: 0.85rem; line-height: 1.6; }
          .plan-desc-heading { font-weight: 600; color: var(--text); font-size: 0.9rem; margin-top: 0.75rem; margin-bottom: 0.35rem; padding: 0.35rem 0.6rem; background: var(--line-2); border-radius: 4px; border-left: 3px solid var(--accent); }
          .plan-desc-heading:first-child { margin-top: 0; }
          .plan-desc-bullet { padding: 0.2rem 0 0.2rem 1rem; position: relative; color: var(--text-2); }
          .plan-desc-bullet::before { content: "•"; position: absolute; left: 0.25rem; color: var(--accent); font-weight: 700; }
          .plan-desc-sub-bullet { padding: 0.15rem 0 0.15rem 2.25rem; position: relative; color: var(--muted); font-size: 0.82rem; }
          .plan-desc-sub-bullet::before { content: "›"; position: absolute; left: 1.5rem; color: var(--line-strong); }
          .plan-desc-para { margin: 0.4rem 0; color: var(--text-2); }
          .plan-inline-code { background: var(--line-2); padding: 0.1rem 0.35rem; border-radius: 3px; font-family: "SF Mono", "Fira Code", monospace; font-size: 0.8rem; color: var(--warn); }

          /* Ghost model badges — provider color + tier icon, sci-fi glow */
          .model-badge { display: inline-flex; align-items: center; gap: 0.25rem; padding: 0.15rem 0.5rem; border-radius: 4px; font-size: 0.7rem; font-weight: 600; letter-spacing: 0.03em; border: 1px solid; font-family: monospace; white-space: nowrap; }
          .model-google { color: var(--accent); border-color: var(--accent)55; background: linear-gradient(135deg, #0d2a5c22, #0d2a5c44); text-shadow: 0 0 8px var(--accent)66; }
          .model-anthropic { color: var(--crit); border-color: #da363655; background: linear-gradient(135deg, #3d1a1a22, #3d1a1a44); text-shadow: 0 0 8px var(--crit)66; }
          .model-openai { color: var(--ok); border-color: var(--ok)55; background: linear-gradient(135deg, var(--ok-bg)22, var(--ok-bg)44); text-shadow: 0 0 8px var(--ok)66; }
          .model-ollama { color: var(--ok); border-color: var(--ok)55; background: linear-gradient(135deg, var(--ok-bg)22, var(--ok-bg)44); text-shadow: 0 0 8px var(--ok)66; }
          .model-bedrock { color: var(--warn); border-color: #d2870055; background: linear-gradient(135deg, #3d2a0022, #3d2a0044); text-shadow: 0 0 8px var(--warn)66; }
          .model-unknown { color: var(--muted); border-color: var(--line)55; background: linear-gradient(135deg, #16161622, #16161644); text-shadow: 0 0 6px var(--muted)44; }
          /* Provider config page */
          .provider-card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 0.75rem 1rem; margin-bottom: 0.5rem; display: flex; align-items: center; gap: 1rem; transition: border-color 0.15s; }
          .provider-card:hover { border-color: var(--line-strong); }
          .provider-card-disabled { opacity: 0.5; }
          .provider-glyph { width: 36px; height: 36px; border-radius: 8px; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 1.1rem; border: 1px solid; flex-shrink: 0; }
          .provider-status-connected { color: var(--ok); }
          .provider-status-configured { color: var(--warn); }
          .provider-status-unconfigured { color: var(--muted); }
          .reorder-btn { background: none; border: 1px solid var(--line); color: var(--muted); border-radius: 4px; cursor: pointer; padding: 0.2rem 0.4rem; font-size: 0.85rem; transition: border-color 0.15s, color 0.15s; }
          .reorder-btn:hover { border-color: var(--accent); color: var(--accent); }
          .reorder-btn:disabled { opacity: 0.3; cursor: not-allowed; }
          .toggle { position: relative; width: 36px; height: 20px; cursor: pointer; flex-shrink: 0; }
          .toggle-track { width: 100%; height: 100%; border-radius: 10px; background: var(--line); transition: background 0.2s; }
          .toggle-track.on { background: var(--ok); }
          .toggle-knob { position: absolute; top: 2px; left: 2px; width: 16px; height: 16px; border-radius: 50%; background: var(--text-2); transition: transform 0.2s; }
          .toggle-knob.on { transform: translateX(16px); }
          .strategy-option { padding: 0.75rem; border: 1px solid var(--line); border-radius: 6px; cursor: pointer; transition: border-color 0.15s, background 0.15s; flex: 1; min-width: 200px; }
          .strategy-option:hover { border-color: var(--accent); }
          .strategy-option.selected { border-color: var(--accent); background: rgba(31,111,235,0.07); }

          .group-progress { width: 60px; height: 4px; background: var(--line); border-radius: 2px; overflow: hidden; margin-left: auto; }
          .group-progress-fill { height: 100%; background: var(--ok); border-radius: 2px; transition: width 0.5s ease; }
          .plan-progress { height: 8px; background: var(--line); border-radius: 4px; overflow: hidden; margin-top: 0.5rem; }
          .plan-progress-fill { height: 100%; border-radius: 4px; transition: width 0.5s ease; background: linear-gradient(90deg, var(--ok), var(--accent)); }
          @keyframes check-in { from { transform: scale(0.5); opacity: 0; } to { transform: scale(1); opacity: 1; } }
          .status-just-done .status-icon { animation: check-in 0.3s ease-out; }

          /* -- Mission detail layout ----------------------------------------- */
          .mission-detail-layout { display: grid; grid-template-columns: 2fr 1fr; gap: 1.25rem; align-items: start; }
          .mission-sidebar { position: sticky; top: 1rem; display: flex; flex-direction: column; gap: 1rem; }
          .sidebar-actions { display: flex; flex-direction: column; gap: 0.4rem; }
          .sidebar-actions .btn { width: 100%; justify-content: center; }
          .goal-text { color: var(--muted); font-size: 0.85rem; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
          .goal-text-full { -webkit-line-clamp: unset; overflow: visible; }
          .goal-toggle { color: var(--accent); font-size: 0.75rem; cursor: pointer; background: none; border: none; padding: 0; margin-top: 0.15rem; }
          .goal-toggle:hover { text-decoration: underline; }
          .op-card { border-bottom: 1px solid var(--line-2); padding: 0.6rem 0.75rem; cursor: pointer; transition: background 0.15s; }
          .op-card:hover { background: var(--panel-2); }
          .op-card:last-child { border-bottom: none; }
          .op-card-done { opacity: 0.6; }
          .op-card-running { border-left: 3px solid var(--accent); background: rgba(31,111,235,0.04); }
          .op-card-failed { border-left: 3px solid var(--crit); background: rgba(248,81,73,0.04); }
          .op-card-blocked { border-left: 3px solid var(--warn); background: rgba(210,153,34,0.04); }
          .op-card-title { display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.3rem; }
          .op-card-title span:first-child { flex-shrink: 0; }
          .op-card-meta { display: flex; align-items: center; gap: 0.5rem; padding-left: 1.7rem; flex-wrap: wrap; }
          .sidebar-stat-row { display: flex; align-items: center; justify-content: space-between; padding: 0.35rem 0; font-size: 0.85rem; transition: background 0.15s; border-radius: 4px; padding: 0.35rem 0.25rem; }
          .sidebar-stat-row:not(:last-child) { border-bottom: 1px solid var(--line-2); }
          .sidebar-stat-row:hover { background: var(--panel-2); }
          .sidebar-stat-label { color: var(--muted); }
          .sidebar-stat-value { font-weight: 700; font-family: monospace; font-size: 1rem; }

          /* -- Op filter chips ------------------------------------------------ */
          .op-filters { display: flex; flex-wrap: wrap; gap: 0.35rem; margin-bottom: 0.75rem; padding-bottom: 0.75rem; border-bottom: 1px solid var(--line-2); }
          .op-filter-chip { display: inline-flex; align-items: center; gap: 0.3rem; padding: 0.2rem 0.6rem; border-radius: 12px; font-size: 0.75rem; font-weight: 500; border: 1px solid var(--line); background: transparent; color: var(--muted); cursor: pointer; transition: all 0.15s; }
          .op-filter-chip:hover { border-color: var(--line-strong); color: var(--text-2); }
          .op-filter-active { background: var(--accent-soft); border-color: var(--accent)55; color: var(--accent); }
          .op-filter-green.op-filter-active { background: var(--ok)22; border-color: var(--ok)55; color: var(--ok); }
          .op-filter-blue.op-filter-active { background: var(--accent)22; border-color: var(--accent)55; color: var(--accent); }
          .op-filter-yellow.op-filter-active { background: var(--warn)22; border-color: var(--warn)55; color: var(--warn); }
          .op-filter-red.op-filter-active { background: var(--crit)22; border-color: var(--crit)55; color: var(--crit); }
          .op-filter-purple.op-filter-active { background: var(--recon)22; border-color: var(--recon)55; color: var(--recon); }
          .op-filter-count { font-family: monospace; font-size: 0.7rem; font-weight: 700; }

          /* -- Approval triage ------------------------------------------------ */
          /* Three blocks, read top down: what failed, what should worry you,
             what is fine. The concerns block is deliberately the same amber
             as .btn-orange — an advisory gap is the thing most likely to be
             the real defect, so it gets action-button weight. */
          .triage-group { border-radius: 6px; padding: 0.7rem 0.85rem; margin-bottom: 0.6rem; }
          .triage-fail { background: var(--crit)15; border: 1px solid var(--crit)55; border-left: 3px solid var(--crit); }
          .triage-concerns { background: var(--warn)15; border: 1px solid var(--warn)55; border-left: 3px solid var(--warn); }
          .triage-ok { background: var(--ground); border: 1px solid var(--line); }
          .triage-group-title { font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; }
          .triage-fail .triage-group-title { color: var(--crit); }
          .triage-concerns .triage-group-title { color: var(--warn); }
          .triage-ok .triage-group-title { color: var(--ok); }
          .triage-items { margin-top: 0.5rem; }
          .triage-item { display: flex; gap: 0.6rem; align-items: flex-start; padding: 0.4rem 0; border-top: 1px solid #ffffff0f; }
          .triage-item:first-child { border-top: none; padding-top: 0; }
          .triage-item-body { min-width: 0; flex: 1; }
          /* The id + verdict is a label; the requirement text is the line
             an operator actually reads. "FR-1 met" is a citation. */
          .triage-item-label { font-size: 0.75rem; font-family: monospace; color: var(--muted); }
          .triage-requirement { font-size: 0.85rem; color: var(--text); margin-top: 0.15rem; }
          .triage-priority { font-size: 0.62rem; margin-left: 0.35rem; vertical-align: middle; }
          .triage-item-kind { font-size: 0.7rem; color: var(--line-strong); font-family: monospace; margin-left: 0.35rem; }
          .triage-criteria { margin: 0.35rem 0 0; padding-left: 1.1rem; font-size: 0.8rem; color: var(--muted); }
          .triage-criteria li { margin-bottom: 0.2rem; }
          .triage-coverage { font-size: 0.72rem; color: var(--muted); font-family: monospace; white-space: nowrap; }
          .triage-detail { font-size: 0.8rem; color: var(--muted); margin-top: 0.35rem; white-space: pre-wrap; }
          .triage-rebuttal { font-size: 0.8rem; color: var(--muted); margin-top: 0.35rem; padding-left: 0.6rem; border-left: 2px solid var(--ok); white-space: pre-wrap; }
          .triage-tally { font-size: 0.78rem; color: var(--muted); font-family: monospace; white-space: nowrap; }
          .triage-warn { background: var(--crit)15; border: 1px solid var(--crit)55; border-radius: 6px; padding: 0.5rem 0.75rem; margin-bottom: 0.6rem; font-size: 0.82rem; color: var(--crit); }

          /* -- Responsive ---------------------------------------------------- */
          @media (max-width: 1024px) { .design-layout { grid-template-columns: 1fr; } .review-split { grid-template-columns: 1fr; } .mission-detail-layout { grid-template-columns: 1fr; } .mission-sidebar { position: static; } }

          /* -- Print --------------------------------------------------------- */
          /* Printing a design review should yield the review, not the app.
             Navigation, controls and transient UI are screen furniture: they
             cost a third of the first page and mean nothing on paper. */
          @media print {
            .nav, .toast-container, .nav-stop, .nav-stop-confirm, .nav-stop-result,
            .btn, button, .flash-info, .flash-error { display: none !important; }

            /* Dark chrome on paper wastes ink and reads worse than plain
               black on white. */
            body { background: #fff !important; color: #111 !important; }
            .main { padding: 0 !important; }
            .panel, .card, .strategy-card {
              background: #fff !important;
              border: 1px solid #999 !important;
              box-shadow: none !important;
              break-inside: avoid;
            }
            .panel-title, .page-title, h1, h2, h3 { color: #000 !important; }
            a { color: #000 !important; text-decoration: none; }

            /* Collapsed sections are collapsed on screen for scrolling, but a
               printout is read linearly — show everything. */
            details { display: block !important; }
            details > summary { display: none !important; }

            /* Side-by-side comparison collapses to full width so nothing is
               clipped at the page edge. */
            .design-layout, .review-split { grid-template-columns: 1fr !important; }
          }
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
        <script src="/assets/sortable.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let Hooks = {};
          Hooks.SessionStore = {
            mounted() {
              let key = this.el.dataset.storeKey;
              let saved = sessionStorage.getItem(key);
              if (saved) { this.pushEvent("restore_session", { key: key, value: saved }); }
              this.handleEvent("store_session", ({ key, value }) => {
                sessionStorage.setItem(key, value);
              });
            }
          };
          // Workflow editor: drag-drop reordering of phase cards.
          // The hook turns the host element into a Sortable; when the user
          // releases a drag, it pushes a `reorder_phases` event with the
          // new ordering of phase ids (taken from each card's data-phase-id).
          Hooks.SortablePhases = {
            mounted() {
              if (!window.Sortable) { return; }
              this.sortable = new Sortable(this.el, {
                handle: ".drag-handle",
                animation: 150,
                ghostClass: "phase-card-ghost",
                chosenClass: "phase-card-chosen",
                onEnd: (evt) => {
                  let order = Array.from(this.el.children)
                    .map(el => el.dataset.phaseId)
                    .filter(id => id);
                  this.pushEvent("reorder_phases", { order: order });
                }
              });
            },
            destroyed() { if (this.sortable) { this.sortable.destroy(); } }
          };
          // Keep a chat/log container pinned to its newest entry.
          Hooks.ScrollBottom = {
            mounted() { this.el.scrollTop = this.el.scrollHeight; },
            updated() { this.el.scrollTop = this.el.scrollHeight; }
          };
          // Planning-studio voice: lazy-loads studio_voice.js on first use and
          // bridges mic/audio via window.GitfStudioVoice (Phoenix Channel).
          Hooks.StudioVoice = {
            mounted() {
              this.handleEvent("voice_toggle", async ({ on, session_id }) => {
                try {
                  if (on) {
                    if (!window.GitfStudioVoice) {
                      await new Promise((resolve, reject) => {
                        const s = document.createElement("script");
                        s.src = "/assets/studio_voice.js";
                        s.onload = resolve; s.onerror = reject;
                        document.head.appendChild(s);
                      });
                    }
                    await window.GitfStudioVoice.start(session_id, {
                      onError: (e) => this.pushEvent("voice_client_error", e || {}),
                    });
                    this.pushEvent("voice_started", {});
                  } else if (window.GitfStudioVoice) {
                    await window.GitfStudioVoice.stop();
                    this.pushEvent("voice_stopped", {});
                  }
                } catch (e) {
                  this.pushEvent("voice_client_error", { reason: String(e) });
                }
              });
            },
            destroyed() { if (window.GitfStudioVoice) { window.GitfStudioVoice.stop(); } }
          };
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken },
            hooks: Hooks
          });
          liveSocket.connect();

          // Keyboard shortcuts — press ? to show help
          const shortcuts = {
            'g o': '/dashboard/',
            'g m': '/dashboard/missions',
            'g g': '/dashboard/ghosts',
            'g c': '/dashboard/costs',
            'g t': '/dashboard/timeline',
            'g h': '/dashboard/health',
            'g s': '/dashboard/shells',
            'g a': '/dashboard/approvals',
            'g p': '/dashboard/progress',
            'g r': '/dashboard/rollback',
            'g q': '/dashboard/merges',
          };
          let keyBuffer = '';
          let keyTimer = null;
          document.addEventListener('keydown', function(e) {
            // Skip if user is typing in an input
            if (['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) return;
            clearTimeout(keyTimer);
            keyBuffer += e.key;
            keyTimer = setTimeout(() => { keyBuffer = ''; }, 500);
            const path = shortcuts[keyBuffer];
            if (path) {
              keyBuffer = '';
              window.location.href = path;
            }
            // ? shows shortcuts help
            if (e.key === '?' && !e.ctrlKey && !e.metaKey) {
              const help = document.getElementById('shortcuts-help');
              if (help) help.style.display = help.style.display === 'none' ? 'block' : 'none';
            }
          });
        </script>
        <div id="shortcuts-help" style="display:none; position:fixed; top:50%; left:50%; transform:translate(-50%,-50%); background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:1.5rem; z-index:10000; max-width:400px; box-shadow:0 8px 24px rgba(0,0,0,0.5)">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
            <span style="color:var(--text); font-weight:600; font-size:1rem">Keyboard Shortcuts</span>
            <span style="color:var(--muted); font-size:0.8rem">Press ? to toggle</span>
          </div>
          <div style="display:grid; grid-template-columns:auto 1fr; gap:0.35rem 1rem; font-size:0.85rem">
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g o</kbd><span style="color:var(--muted)">Overview</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g m</kbd><span style="color:var(--muted)">Missions</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g g</kbd><span style="color:var(--muted)">Ghosts</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g c</kbd><span style="color:var(--muted)">Costs</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g t</kbd><span style="color:var(--muted)">Timeline</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g h</kbd><span style="color:var(--muted)">Health</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g s</kbd><span style="color:var(--muted)">Shells</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g a</kbd><span style="color:var(--muted)">Approvals</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g p</kbd><span style="color:var(--muted)">Activity</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g r</kbd><span style="color:var(--muted)">Rollback</span>
            <kbd style="background:var(--ground); border:1px solid var(--line); border-radius:3px; padding:0.1rem 0.4rem; font-family:monospace; color:var(--text-2)">g q</kbd><span style="color:var(--muted)">Merge Queue</span>
          </div>
        </div>
      </body>
    </html>
    """
  end
end
