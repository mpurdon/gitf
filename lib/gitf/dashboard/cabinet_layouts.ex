defmodule GiTF.Dashboard.CabinetLayouts do
  @moduledoc """
  Root layout for the Cabinet Console — the Cabinet's OWN chrome, not the
  factory dashboard's. Carries the control-surface design tokens and the
  Console's component styles (GiTF Control Surface plan §06/§07: soft
  rounded panels, tinted status pills, dark icon rail; dark-first like
  the factory, semantic colour only).
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias GiTF.Dashboard.Surface

  # HEEx emits <style> contents as raw text, so the sheet is built here. The
  # shared half is `Surface.base/0` — the Cabinet, the Console and the Catwalk
  # are three views of one system and had been three copies of one palette.
  @own """
  a{color:var(--accent);text-decoration:none}
  button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;text-align:left}
  button:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
  .mono{font-family:var(--mono);font-variant-numeric:tabular-nums}
  .muted{color:var(--ink-3)}
  svg.ico{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;flex:0 0 auto}

  /* frame: rail · workspace · inspector */
  .console{display:grid;grid-template-columns:80px minmax(0,1fr) 400px;min-height:100vh}
  @media (max-width:1180px){.console{grid-template-columns:80px minmax(0,1fr) 340px}}
  @media (max-width:900px){.console{grid-template-columns:80px minmax(0,1fr)}.inspector{display:none}}

  .rail{background:var(--rail);color:var(--rail-text);display:flex;flex-direction:column;align-items:center;padding:14px 0;gap:2px;position:sticky;top:0;height:100vh}
  .rail .logo{width:40px;height:40px;border-radius:10px;background:var(--accent);color:#fff;display:grid;place-items:center;margin-bottom:14px}
  .rail button{width:64px;padding:9px 0 7px;border-radius:10px;display:flex;flex-direction:column;align-items:center;gap:4px;font-size:10px;letter-spacing:.02em;color:var(--rail-text)}
  .rail button:hover{color:var(--rail-on)}
  .rail button.on{background:var(--rail-on);color:var(--rail-on)}
  .rail button .badge-anchor{position:relative}
  .rail button .count{position:absolute;top:-5px;right:-10px;background:var(--warn);color:#fff;font-family:var(--mono);font-size:9px;line-height:1;padding:2px 4px;border-radius:8px}
  .rail .spacer{flex:1}

  .workspace{display:flex;flex-direction:column;min-width:0;padding:16px 28px 48px;gap:20px}
  .crumbs{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--ink-3);padding-top:2px}
  .crumbs b{color:var(--ink);font-weight:600;font-size:15px}
  .view-head{display:flex;align-items:baseline;gap:12px}
  .view-head h1{font-size:20px;font-weight:600;letter-spacing:-.01em}
  .view-head .sub{color:var(--ink-3);font-size:13px}
  .view-head .end,.fleet-actions .end,.opening .end{margin-left:auto}

  .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);overflow:hidden}
  .panel-head{display:flex;align-items:center;gap:10px;padding:14px 20px;border-bottom:1px solid var(--line-soft)}
  .panel-head h2{font-size:14px;font-weight:600}
  .panel-head .end{margin-left:auto;font-size:13px;color:var(--accent);font-weight:500}

  .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px}
  .tile{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:16px 18px;display:flex;flex-direction:column;gap:4px}
  .tile .k{font-size:11.5px;color:var(--ink-3);letter-spacing:.04em;text-transform:uppercase;font-weight:600}
  .tile .v{font-size:22px;font-weight:600;letter-spacing:-.01em;display:flex;align-items:center;gap:10px}
  .tile .s{font-size:12.5px;color:var(--ink-3)}

  .pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;padding:3px 10px;border-radius:999px;white-space:nowrap}
  .pill .dot{width:6px;height:6px;border-radius:50%;background:currentColor}
  .pill.ok{color:var(--ok);background:var(--ok-bg)}
  .pill.warn{color:var(--warn);background:var(--warn-bg)}
  .pill.crit{color:var(--crit);background:var(--crit-bg)}
  .pill.recon{color:var(--recon);background:var(--recon-bg)}
  .pill.recon .dot{animation:cab-pulse 1.6s ease-in-out infinite}
  .pill.off{color:var(--off);background:var(--off-bg)}
  @keyframes cab-pulse{0%,100%{opacity:1}50%{opacity:.35}}
  @media (prefers-reduced-motion:reduce){.pill.recon .dot{animation:none}}
  .tag{display:inline-flex;font-size:11.5px;font-weight:600;padding:2px 9px;border-radius:999px;background:var(--off-bg);color:var(--ink-2)}
  .tag.bug{background:var(--crit-bg);color:var(--crit)}
  .tag.feature{background:var(--warn-bg);color:var(--warn)}
  .tag.pr_review{background:var(--recon-bg);color:var(--recon)}

  .mrow{display:grid;grid-template-columns:minmax(200px,1.3fr) auto minmax(140px,1fr) minmax(130px,1fr) auto;gap:18px;align-items:center;width:100%;padding:16px 20px;border-bottom:1px solid var(--line-soft)}
  .mrow:last-child{border-bottom:0}
  .mrow:hover{background:var(--panel-2)}
  .mrow.sel{background:var(--accent-soft)}
  .avatar{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:700;font-size:14px;color:#fff;flex:0 0 auto;background:linear-gradient(135deg,#2E7DF7,#5A5FE0)}
  .avatar.dim{background:linear-gradient(135deg,#5B6572,#3A424D)}
  .who{display:flex;align-items:center;gap:14px;min-width:0}
  .who .nm{font-weight:600;font-size:15px}
  .who .sub{font-size:12px;color:var(--ink-3);font-family:var(--mono);margin-top:2px}
  .stat{display:flex;flex-direction:column;gap:2px}
  .stat .k{font-size:11px;color:var(--ink-3);letter-spacing:.03em;text-transform:uppercase;font-weight:600}
  .stat .v{font-size:13.5px;color:var(--ink-2)}
  .stat .v b{font-family:var(--mono);font-weight:500;color:var(--ink)}

  .fleet.sel{border-color:var(--accent)}
  .fleet-head{display:flex;align-items:center;justify-content:space-between;gap:16px;width:100%;padding:16px 20px;text-align:left}
  .fleet-head:hover{background:var(--panel-2)}
  .fleet-head .strip{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  .fleet-metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px 18px;padding:12px 20px 14px;border-top:1px solid var(--line-soft)}
  .fleet-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:12px 20px 14px;border-top:1px solid var(--line-soft)}
  .btn[disabled]{opacity:.5;pointer-events:none}
  .opening{display:flex;align-items:center;gap:14px;padding:14px 20px;font-size:13.5px;color:var(--ink-2)}

  /* The row selects; the actions sit BESIDE it as real buttons. They
   used to be spans nested inside the row's <button>, which is not
   focusable and made Start/Dismiss unreachable from a keyboard. */
  .irow-wrap{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;
  border-bottom:1px solid var(--line-soft)}
  .irow-wrap:last-child{border-bottom:0}
  .irow-wrap:hover{background:var(--panel-2)}
  .irow-wrap.sel{background:var(--accent-soft)}
  .irow-actions{display:inline-flex;gap:6px;padding-right:20px}
  .irow{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;gap:16px;align-items:center;width:100%;padding:14px 20px;border-bottom:1px solid var(--line-soft)}
  .irow:last-child{border-bottom:0}
  .irow-wrap .irow{border-bottom:0}
  .irow:hover{background:var(--panel-2)}
  .irow.sel{background:var(--accent-soft)}
  .irow .t1{display:block;font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .irow .t2{display:block;font-size:12.5px;color:var(--ink-3);margin-top:2px}
  .irow .t2 em{font-style:normal;color:var(--ink-2);font-weight:600}
  .when{font-family:var(--mono);font-size:12px;color:var(--ink-3);white-space:nowrap}

  .btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;font-size:13px;font-weight:600;padding:8px 14px;border-radius:8px;background:var(--panel);border:1px solid var(--line);color:var(--ink-2);white-space:nowrap}
  .btn:hover{background:var(--panel-2)}
  .btn.pri{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
  .btn.sm{padding:6px 11px;font-size:12.5px}
  .seg{display:inline-flex;background:var(--panel-2);border:1px solid var(--line);border-radius:9px;padding:3px;gap:2px}
  .seg button{padding:6px 14px;font-size:12.5px;font-weight:600;color:var(--ink-3);border-radius:6px;text-align:center}
  .seg button.on{background:var(--panel);color:var(--ink);box-shadow:var(--shadow)}

  .polgrid{width:100%;border-collapse:collapse}
  .polgrid th{font-size:11.5px;letter-spacing:.04em;text-transform:uppercase;color:var(--ink-3);font-weight:600;text-align:left;padding:12px 20px;border-bottom:1px solid var(--line-soft)}
  .polgrid td{padding:13px 20px;border-bottom:1px solid var(--line-soft);vertical-align:middle}
  .polgrid tr:last-child td{border-bottom:0}
  .polgrid .n{font-weight:600}
  .cell{display:inline-flex;align-items:center;gap:7px;font-size:12.5px;font-weight:600;padding:5px 12px;border-radius:8px}
  .cell.wake{background:var(--ok-bg);color:var(--ok)}
  .cell.queue{background:var(--warn-bg);color:var(--warn)}
  .cell.drop{background:var(--off-bg);color:var(--off)}
  .footnote{font-size:12.5px;color:var(--ink-3);padding:12px 20px;border-top:1px solid var(--line-soft)}
  pre.raw{font-family:var(--mono);font-size:12px;line-height:1.6;color:var(--ink-2);background:var(--panel-2);padding:16px 20px;overflow:auto}

  .sysnode{display:grid;grid-template-columns:auto 1.2fr 1fr 1fr 1fr;gap:16px;align-items:center;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:14px 18px;width:100%}
  .sysnode:hover{border-color:var(--accent)}
  .sysnode .nm{font-weight:600;display:flex;flex-direction:column;text-align:left}
  .sysnode .nm .ty{font-size:10.5px;color:var(--ink-3);letter-spacing:.05em;text-transform:uppercase;font-weight:600}
  .sysnode .kv{font-size:12.5px;color:var(--ink-2)}
  .sysnode .kv b{font-family:var(--mono);font-weight:500;color:var(--ink)}
  .sysicon{width:36px;height:36px;border-radius:9px;background:var(--panel-2);display:grid;place-items:center;color:var(--ink-2)}
  .systree{display:flex;flex-direction:column;gap:10px}
  .indent-1{margin-left:34px}.indent-2{margin-left:68px}

  .inspector{border-left:1px solid var(--line);background:var(--panel);display:flex;flex-direction:column;position:sticky;top:0;height:100vh;overflow:auto}
  .insp-head{padding:22px 24px 14px}
  .insp-head .ty{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-3);font-weight:600}
  .insp-head h2{margin:6px 0 8px;font-size:19px;font-weight:600;letter-spacing:-.01em;line-height:1.3}
  .insp-head .strip{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  .insp-actions{display:flex;gap:8px;margin-top:14px;flex-wrap:wrap}
  .itabs{display:flex;gap:4px;padding:0 20px;border-bottom:1px solid var(--line-soft)}
  .itabs button{padding:10px 12px;font-size:13px;font-weight:600;color:var(--ink-3);border-bottom:2px solid transparent;margin-bottom:-1px}
  .itabs button.on{color:var(--accent);border-bottom-color:var(--accent)}
  .ipane{padding:8px 24px 26px}
  .inspector .kv{display:grid;grid-template-columns:96px 1fr;gap:9px 14px;font-size:13px;padding:14px 0;border-bottom:1px solid var(--line-soft)}
  .inspector .kv dt{color:var(--ink-3);font-weight:600;font-size:12px}
  .inspector .kv dd{color:var(--ink-2)}
  .rel{display:flex;flex-direction:column;gap:10px;padding:14px 0;border-bottom:1px solid var(--line-soft);font-size:13px}
  .rel .verb{font-size:10.5px;color:var(--ink-3);letter-spacing:.05em;text-transform:uppercase;font-weight:600;display:block;margin-bottom:1px}
  .decision{padding:14px 0;border-bottom:1px solid var(--line-soft)}
  .decision .reason{color:var(--ink-2);font-size:13px;margin:6px 0 10px}
  .factor{display:grid;grid-template-columns:1fr auto;gap:12px;font-size:13px;padding:8px 0;border-top:1px solid var(--line-soft)}
  .factor .v{font-family:var(--mono);color:var(--ink-3);font-size:11.5px;text-align:right}
  .mini-head{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-3);font-weight:600;padding:16px 0 6px}
  .inspector pre.raw{border-radius:10px;border:1px solid var(--line-soft)}
  .empty{color:var(--ink-3);font-size:13px;padding:16px 20px}

  .field{display:grid;gap:4px;margin-bottom:12px}
  .field label{font-size:11.5px;color:var(--ink-3);letter-spacing:.04em;text-transform:uppercase;font-weight:600}
  .field input{font:inherit;color:var(--ink);background:var(--panel-2);border:1px solid var(--line);border-radius:8px;padding:8px 12px;width:100%}
  .field input:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:var(--accent)}
  .formgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:0 16px;padding:14px 20px 4px}
  .formfoot{display:flex;gap:8px;justify-content:flex-end;padding:0 20px 16px}
  .cellbtn{border:0;background:none;padding:0;cursor:pointer}
  .flash{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--panel);border:1px solid var(--line);border-radius:10px;box-shadow:var(--shadow);padding:10px 18px;font-size:13.5px;z-index:50}
  .flash.err{border-color:var(--crit);color:var(--crit)}
  """

  defp stylesheet, do: "<style>" <> Surface.base() <> "\n" <> @own <> "</style>"

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Cabinet</title>
        {Phoenix.HTML.raw(stylesheet())}
      </head>
      <body>
        {@inner_content}
        <script src="/assets/phoenix.min.js">
        </script>
        <script src="/assets/phoenix_live_view.min.js">
        </script>
        <script>
          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
