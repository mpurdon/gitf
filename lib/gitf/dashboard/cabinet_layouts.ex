defmodule GiTF.Dashboard.CabinetLayouts do
  @moduledoc """
  Root layout for the Cabinet Console — the Cabinet's OWN chrome, not the
  factory dashboard's. Carries the control-surface design tokens and the
  Console's component styles (GiTF Control Surface plan §06/§07: cool
  ground, soft rounded panels, tinted status pills, dark icon rail;
  dark and light designed separately, semantic colour only).
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Cabinet</title>
        <style>
          :root{
            --ground:#F4F6F9; --panel:#FFFFFF; --panel-2:#F8FAFC; --line:#E6EAF0; --line-2:#EDF0F4;
            --text:#212832; --text-2:#4E5866; --muted:#8B95A5;
            --accent:#2E7DF7; --accent-ink:#FFFFFF; --accent-soft:#EBF2FE;
            --rail:#101821; --rail-text:#9AA7B8; --rail-on:#FFFFFF; --rail-active:rgba(255,255,255,.08);
            --ok:#1E9E5C; --ok-bg:#E6F6EE; --warn:#B27A17; --warn-bg:#FCF3E3;
            --crit:#C93B3B; --crit-bg:#FCEAEA; --recon:#6B4FD8; --recon-bg:#F0EBFC;
            --off:#7A8594; --off-bg:#EEF1F4;
            --shadow:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.06);
            --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
            --sans:system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
          }
          @media (prefers-color-scheme: dark){
            :root{
              --ground:#14181E; --panel:#1C2129; --panel-2:#20262F; --line:#2A313B; --line-2:#252C35;
              --text:#E9EDF2; --text-2:#B4BDC9; --muted:#8B95A5;
              --accent:#4C9AFF; --accent-ink:#0E1218; --accent-soft:#1B2C45;
              --rail:#0D1218; --rail-text:#8B98A9; --rail-on:#FFFFFF; --rail-active:rgba(255,255,255,.07);
              --ok:#43C383; --ok-bg:#15291F; --warn:#E0A82E; --warn-bg:#2E2513;
              --crit:#EA6A62; --crit-bg:#321B1B; --recon:#A78BFA; --recon-bg:#241E38;
              --off:#8B95A5; --off-bg:#232933;
              --shadow:0 1px 2px rgba(0,0,0,.3);
            }
          }
          *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
          html{font-size:14px}
          body{background:var(--ground);color:var(--text);font-family:var(--sans);line-height:1.5;min-height:100vh}
          a{color:var(--accent);text-decoration:none}
          button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;text-align:left}
          button:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
          .mono{font-family:var(--mono);font-variant-numeric:tabular-nums}
          .muted{color:var(--muted)}
          svg.ico{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;flex:0 0 auto}

          /* frame: rail · workspace · inspector */
          .console{display:grid;grid-template-columns:80px minmax(0,1fr) 400px;min-height:100vh}
          @media (max-width:1180px){.console{grid-template-columns:80px minmax(0,1fr) 340px}}
          @media (max-width:900px){.console{grid-template-columns:80px minmax(0,1fr)}.inspector{display:none}}

          .rail{background:var(--rail);color:var(--rail-text);display:flex;flex-direction:column;align-items:center;padding:14px 0;gap:2px;position:sticky;top:0;height:100vh}
          .rail .logo{width:40px;height:40px;border-radius:10px;background:var(--accent);color:#fff;display:grid;place-items:center;margin-bottom:14px}
          .rail button{width:64px;padding:9px 0 7px;border-radius:10px;display:flex;flex-direction:column;align-items:center;gap:4px;font-size:10px;letter-spacing:.02em;color:var(--rail-text)}
          .rail button:hover{color:var(--rail-on)}
          .rail button.on{background:var(--rail-active);color:var(--rail-on)}
          .rail button .badge-anchor{position:relative}
          .rail button .count{position:absolute;top:-5px;right:-10px;background:var(--warn);color:#fff;font-family:var(--mono);font-size:9px;line-height:1;padding:2px 4px;border-radius:8px}
          .rail .spacer{flex:1}

          .workspace{display:flex;flex-direction:column;min-width:0;padding:16px 28px 48px;gap:20px}
          .crumbs{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--muted);padding-top:2px}
          .crumbs b{color:var(--text);font-weight:600;font-size:15px}
          .view-head{display:flex;align-items:baseline;gap:12px}
          .view-head h1{font-size:20px;font-weight:600;letter-spacing:-.01em}
          .view-head .sub{color:var(--muted);font-size:13px}
          .view-head .end{margin-left:auto}

          .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);overflow:hidden}
          .panel-head{display:flex;align-items:center;gap:10px;padding:14px 20px;border-bottom:1px solid var(--line-2)}
          .panel-head h2{font-size:14px;font-weight:600}
          .panel-head .end{margin-left:auto;font-size:13px;color:var(--accent);font-weight:500}

          .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px}
          .tile{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:16px 18px;display:flex;flex-direction:column;gap:4px}
          .tile .k{font-size:11.5px;color:var(--muted);letter-spacing:.04em;text-transform:uppercase;font-weight:600}
          .tile .v{font-size:22px;font-weight:600;letter-spacing:-.01em;display:flex;align-items:center;gap:10px}
          .tile .s{font-size:12.5px;color:var(--muted)}

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
          .tag{display:inline-flex;font-size:11.5px;font-weight:600;padding:2px 9px;border-radius:999px;background:var(--off-bg);color:var(--text-2)}
          .tag.bug{background:var(--crit-bg);color:var(--crit)}
          .tag.feature{background:var(--warn-bg);color:var(--warn)}
          .tag.pr_review{background:var(--recon-bg);color:var(--recon)}

          .mrow{display:grid;grid-template-columns:minmax(200px,1.3fr) auto minmax(140px,1fr) minmax(130px,1fr) auto;gap:18px;align-items:center;width:100%;padding:16px 20px;border-bottom:1px solid var(--line-2)}
          .mrow:last-child{border-bottom:0}
          .mrow:hover{background:var(--panel-2)}
          .mrow.sel{background:var(--accent-soft)}
          .avatar{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:700;font-size:14px;color:#fff;flex:0 0 auto;background:linear-gradient(135deg,#2E7DF7,#5A5FE0)}
          .avatar.dim{background:linear-gradient(135deg,#5B6572,#3A424D)}
          .who{display:flex;align-items:center;gap:14px;min-width:0}
          .who .nm{font-weight:600;font-size:15px}
          .who .sub{font-size:12px;color:var(--muted);font-family:var(--mono);margin-top:2px}
          .stat{display:flex;flex-direction:column;gap:2px}
          .stat .k{font-size:11px;color:var(--muted);letter-spacing:.03em;text-transform:uppercase;font-weight:600}
          .stat .v{font-size:13.5px;color:var(--text-2)}
          .stat .v b{font-family:var(--mono);font-weight:500;color:var(--text)}

          .irow{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto;gap:16px;align-items:center;width:100%;padding:14px 20px;border-bottom:1px solid var(--line-2)}
          .irow:last-child{border-bottom:0}
          .irow:hover{background:var(--panel-2)}
          .irow.sel{background:var(--accent-soft)}
          .irow .t1{font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .irow .t2{font-size:12.5px;color:var(--muted);margin-top:2px}
          .irow .t2 em{font-style:normal;color:var(--text-2);font-weight:600}
          .when{font-family:var(--mono);font-size:12px;color:var(--muted);white-space:nowrap}

          .btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;font-size:13px;font-weight:600;padding:8px 14px;border-radius:8px;background:var(--panel);border:1px solid var(--line);color:var(--text-2);white-space:nowrap}
          .btn:hover{background:var(--panel-2)}
          .btn.pri{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
          .btn.sm{padding:6px 11px;font-size:12.5px}
          .seg{display:inline-flex;background:var(--panel-2);border:1px solid var(--line);border-radius:9px;padding:3px;gap:2px}
          .seg button{padding:6px 14px;font-size:12.5px;font-weight:600;color:var(--muted);border-radius:6px;text-align:center}
          .seg button.on{background:var(--panel);color:var(--text);box-shadow:var(--shadow)}

          .polgrid{width:100%;border-collapse:collapse}
          .polgrid th{font-size:11.5px;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);font-weight:600;text-align:left;padding:12px 20px;border-bottom:1px solid var(--line-2)}
          .polgrid td{padding:13px 20px;border-bottom:1px solid var(--line-2);vertical-align:middle}
          .polgrid tr:last-child td{border-bottom:0}
          .polgrid .n{font-weight:600}
          .cell{display:inline-flex;align-items:center;gap:7px;font-size:12.5px;font-weight:600;padding:5px 12px;border-radius:8px}
          .cell.wake{background:var(--ok-bg);color:var(--ok)}
          .cell.queue{background:var(--warn-bg);color:var(--warn)}
          .cell.drop{background:var(--off-bg);color:var(--off)}
          .footnote{font-size:12.5px;color:var(--muted);padding:12px 20px;border-top:1px solid var(--line-2)}
          pre.raw{font-family:var(--mono);font-size:12px;line-height:1.6;color:var(--text-2);background:var(--panel-2);padding:16px 20px;overflow:auto}

          .sysnode{display:grid;grid-template-columns:auto 1.2fr 1fr 1fr 1fr;gap:16px;align-items:center;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:14px 18px;width:100%}
          .sysnode:hover{border-color:var(--accent)}
          .sysnode .nm{font-weight:600;display:flex;flex-direction:column;text-align:left}
          .sysnode .nm .ty{font-size:10.5px;color:var(--muted);letter-spacing:.05em;text-transform:uppercase;font-weight:600}
          .sysnode .kv{font-size:12.5px;color:var(--text-2)}
          .sysnode .kv b{font-family:var(--mono);font-weight:500;color:var(--text)}
          .sysicon{width:36px;height:36px;border-radius:9px;background:var(--panel-2);display:grid;place-items:center;color:var(--text-2)}
          .systree{display:flex;flex-direction:column;gap:10px}
          .indent-1{margin-left:34px}.indent-2{margin-left:68px}

          .inspector{border-left:1px solid var(--line);background:var(--panel);display:flex;flex-direction:column;position:sticky;top:0;height:100vh;overflow:auto}
          .insp-head{padding:22px 24px 14px}
          .insp-head .ty{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);font-weight:600}
          .insp-head h2{margin:6px 0 8px;font-size:19px;font-weight:600;letter-spacing:-.01em;line-height:1.3}
          .insp-head .strip{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
          .insp-actions{display:flex;gap:8px;margin-top:14px;flex-wrap:wrap}
          .itabs{display:flex;gap:4px;padding:0 20px;border-bottom:1px solid var(--line-2)}
          .itabs button{padding:10px 12px;font-size:13px;font-weight:600;color:var(--muted);border-bottom:2px solid transparent;margin-bottom:-1px}
          .itabs button.on{color:var(--accent);border-bottom-color:var(--accent)}
          .ipane{padding:8px 24px 26px}
          .insp .kv{display:grid;grid-template-columns:96px 1fr;gap:9px 14px;font-size:13px;padding:14px 0;border-bottom:1px solid var(--line-2)}
          .insp .kv dt{color:var(--muted);font-weight:600;font-size:12px}
          .insp .kv dd{color:var(--text-2)}
          .rel{display:flex;flex-direction:column;gap:10px;padding:14px 0;border-bottom:1px solid var(--line-2);font-size:13px}
          .rel .verb{font-size:10.5px;color:var(--muted);letter-spacing:.05em;text-transform:uppercase;font-weight:600;display:block;margin-bottom:1px}
          .decision{padding:14px 0;border-bottom:1px solid var(--line-2)}
          .decision .reason{color:var(--text-2);font-size:13px;margin:6px 0 10px}
          .factor{display:grid;grid-template-columns:1fr auto;gap:12px;font-size:13px;padding:8px 0;border-top:1px solid var(--line-2)}
          .factor .v{font-family:var(--mono);color:var(--muted);font-size:11.5px;text-align:right}
          .mini-head{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);font-weight:600;padding:16px 0 6px}
          .insp pre.raw{border-radius:10px;border:1px solid var(--line-2)}
          .empty{color:var(--muted);font-size:13px;padding:16px 20px}

          .field{display:grid;gap:4px;margin-bottom:12px}
          .field label{font-size:11.5px;color:var(--muted);letter-spacing:.04em;text-transform:uppercase;font-weight:600}
          .field input{font:inherit;color:var(--text);background:var(--panel-2);border:1px solid var(--line);border-radius:8px;padding:8px 12px;width:100%}
          .field input:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:var(--accent)}
          .formgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:0 16px;padding:14px 20px 4px}
          .formfoot{display:flex;gap:8px;justify-content:flex-end;padding:0 20px 16px}
          .cellbtn{border:0;background:none;padding:0;cursor:pointer}
          .flash{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--panel);border:1px solid var(--line);border-radius:10px;box-shadow:var(--shadow);padding:10px 18px;font-size:13.5px;z-index:50}
          .flash.err{border-color:var(--crit);color:var(--crit)}
        </style>
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
