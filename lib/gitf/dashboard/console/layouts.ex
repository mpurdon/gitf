defmodule GiTF.Dashboard.Console.Layouts do
  @moduledoc """
  Root layout for the GiTF Console.

  One stylesheet for one surface: the tree that moves you, the object page that
  explains, and the primitives both are built from. Descends from
  `CabinetLayouts`' palette so the Console and the Catwalk still read as one
  product, with three things deliberately changed.

  **Every colour is a token, and no token refers to itself.** The factory's
  sheet shipped `--recon: var(--recon)`, a cycle CSS resolves to the
  guaranteed-invalid value, which silently discarded every rule that read it.
  `test/gitf/dashboard/tokens_test.exs` now fails the build on either mistake.

  **Spacing, radius and the type scale are tokens too.** The Cabinet's sheet
  hard-coded twelve font sizes and a dozen radii inline, so "make it denser"
  meant a hundred edits and a slightly different answer each time.

  **Components, not repeated markup.** A ministry's identity block was written
  out four times in the old console with three different sets of fields. Here
  the primitives live in `GiTF.Dashboard.Console.Components` and this file only
  styles them.
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
        <title>{assigns[:page_title] || "GiTF Console"}</title>
        <style>
          :root{
            /* surfaces */
            --ground:#12161C; --stage:#0D1116; --panel:#191E26; --panel-2:#1F252E;
            --line:#272E39; --line-soft:#212832;
            --rail:#0B0F14; --rail-text:#8892A2; --rail-on:#FFFFFF;
            /* ink */
            --ink:#E8EDF3; --ink-2:#AAB4C2; --ink-3:#78838F;
            /* one accent, kept away from the semantic set */
            --accent:#4C9AFF; --accent-soft:#16283F; --accent-ink:#0B0F14;
            /* semantic: colour that means something */
            --ok:#43C383; --ok-bg:#12271D; --warn:#E0A82E; --warn-bg:#2B2312;
            --crit:#EA6A62; --crit-bg:#2F1A1A; --recon:#A78BFA; --recon-bg:#221C35;
            --off:#8B95A5; --off-bg:#212832;
            /* scale — the whole reason the old sheet needed a hundred edits */
            --s1:4px; --s2:6px; --s3:9px; --s4:14px; --s5:20px; --s6:28px;
            --r:4px; --r2:6px;
            --t-xs:10px; --t-sm:11.5px; --t-md:13px; --t-lg:14px; --t-xl:21px;
            --rail-w:52px; --tree-w:296px; --facet-w:264px;
            --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
            --sans:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
            color-scheme:dark;
          }
          *{box-sizing:border-box}
          html{font-size:100%}
          body{margin:0;background:var(--stage);color:var(--ink);font-family:var(--sans);
            font-size:var(--t-lg);line-height:1.5;-webkit-font-smoothing:antialiased}
          button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;text-align:left}
          a{color:inherit;text-decoration:none}
          input,select{font:inherit;color:inherit;background:var(--panel-2);
            border:1px solid var(--line);border-radius:var(--r);padding:var(--s1) var(--s2);
            font-size:var(--t-md)}
          input:focus,select:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:var(--accent)}
          :focus-visible{outline:2px solid var(--accent);outline-offset:1px}
          h1,h2,h3,h4{margin:0;text-wrap:balance}
          code{font-family:var(--mono);font-size:.9em;background:var(--panel-2);
            padding:1px 5px;border-radius:3px}

          /* -------- primitives -------- */
          .dot{width:7px;height:7px;border-radius:50%;flex:0 0 auto;background:var(--off);display:inline-block}
          .dot.ok{background:var(--ok)} .dot.warn{background:var(--warn)}
          .dot.crit{background:var(--crit)} .dot.recon{background:var(--recon)}
          .dot.acc{background:var(--accent)}
          .pill{display:inline-flex;align-items:center;gap:5px;padding:1px 7px;border-radius:999px;
            font-size:var(--t-sm);font-weight:500;background:var(--off-bg);color:var(--off);white-space:nowrap}
          .pill.ok{background:var(--ok-bg);color:var(--ok)}
          .pill.warn{background:var(--warn-bg);color:var(--warn)}
          .pill.crit{background:var(--crit-bg);color:var(--crit)}
          .pill.recon{background:var(--recon-bg);color:var(--recon)}
          .pill.acc{background:var(--accent-soft);color:var(--accent)}
          .lbl{font-size:var(--t-xs);font-weight:600;letter-spacing:.09em;
            text-transform:uppercase;color:var(--ink-3)}
          .note{font-size:var(--t-sm);color:var(--ink-3)}
          .mono{font-family:var(--mono);font-variant-numeric:tabular-nums}
          .metric{display:flex;flex-direction:column;gap:2px;min-width:0}
          .metric .v{font-family:var(--mono);font-size:var(--t-md);
            font-variant-numeric:tabular-nums;white-space:nowrap}
          .btn{display:inline-flex;align-items:center;gap:var(--s2);padding:5px 11px;
            border:1px solid var(--line);border-radius:var(--r);background:var(--panel-2);
            font-size:var(--t-md);font-weight:500;color:var(--ink-2)}
          .btn:hover{border-color:var(--ink-3);color:var(--ink)}
          .btn.pri{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
          .btn.pri:hover{filter:brightness(1.08)}
          .btn.sm{padding:3px 8px;font-size:var(--t-sm)}
          .btn.danger{color:var(--crit);border-color:var(--crit-bg)}
          .btn[disabled]{opacity:.45;pointer-events:none}
          .chip{display:inline-flex;align-items:center;gap:5px;padding:2px 8px;border-radius:999px;
            border:1px solid var(--line);background:var(--panel-2);font-size:var(--t-sm);
            font-family:var(--mono);color:var(--ink-2)}
          .chip.on{border-color:var(--accent);background:var(--accent-soft);color:var(--accent)}
          .seg{display:inline-flex;border:1px solid var(--line);border-radius:var(--r);overflow:hidden}
          .seg button{padding:3px 10px;font-size:var(--t-md);color:var(--ink-3);background:var(--panel)}
          .seg button[aria-current="true"]{background:var(--panel-2);color:var(--ink);font-weight:500}

          /* -------- frame -------- */
          .console{height:100vh;min-height:640px;display:grid;
            grid-template-columns:var(--rail-w) var(--tree-w) minmax(0,1fr);overflow:hidden}
          .pane{min-width:0;min-height:0;overflow:auto}
          .icons{background:var(--rail);display:flex;flex-direction:column;align-items:center;
            gap:3px;padding:var(--s3) 0}
          .icons a{width:38px;height:36px;border-radius:5px;color:var(--rail-text);
            display:grid;place-items:center;font-size:15px}
          .icons a:hover{background:rgba(255,255,255,.07);color:var(--rail-on)}
          .icons a[aria-current="page"]{background:rgba(255,255,255,.11);color:var(--rail-on)}
          .icons .spacer{margin-top:auto}
          .icons .badge{position:relative}
          .icons .badge::after{content:attr(data-n);position:absolute;top:2px;right:1px;
            min-width:14px;height:14px;border-radius:7px;background:var(--warn);color:#12161C;
            font-size:9px;font-weight:700;display:grid;place-items:center;padding:0 3px;
            font-family:var(--mono)}

          /* -------- tree -------- */
          .tree{background:var(--panel);border-right:1px solid var(--line);
            padding:var(--s3) 0 var(--s6);font-size:var(--t-md)}
          .tsearch{margin:0 var(--s3) var(--s3);display:flex;align-items:center;gap:7px;
            padding:5px var(--s3);border:1px solid var(--line);border-radius:var(--r);
            background:var(--stage);font-size:var(--t-sm);color:var(--ink-3)}
          .tnode{display:flex;align-items:center;gap:7px;width:100%;padding:var(--s1) var(--s3) var(--s1) 0;
            white-space:nowrap;overflow:hidden}
          .tnode:hover{background:var(--panel-2)}
          .tnode[aria-current="page"]{background:var(--accent-soft);color:var(--accent);font-weight:500}
          .tnode .tw{width:12px;flex:0 0 auto;color:var(--ink-3);font-size:9px;text-align:center}
          .tnode .tn{overflow:hidden;text-overflow:ellipsis}
          .tnode .tt{margin-left:auto;font-family:var(--mono);font-size:var(--t-xs);
            color:var(--ink-3);padding-left:var(--s2)}
          .tnode .tt.warn{color:var(--warn);font-weight:600}
          .tnode .tt.acc{color:var(--accent);font-weight:600}
          .tnode .tt.muted{opacity:.6}
          .tgroup{font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);
            font-weight:600;padding:var(--s3) 0 3px}
          .thint{font-size:var(--t-sm);color:var(--ink-3);padding:var(--s1) 0}

          /* -------- workspace -------- */
          .ws{display:flex;flex-direction:column;height:100%}
          .scopebar{display:flex;align-items:center;gap:var(--s2);padding:0 var(--s5);height:44px;
            flex:0 0 auto;border-bottom:1px solid var(--line);background:var(--panel)}
          .crumb{display:inline-flex;align-items:center;gap:5px;padding:3px var(--s2);
            border-radius:var(--r);font-size:var(--t-md);color:var(--ink-2)}
          .crumb:hover{background:var(--panel-2);color:var(--ink)}
          .crumb[aria-current="page"]{color:var(--ink);font-weight:500}
          .sep{color:var(--ink-3);font-size:var(--t-sm)}
          .objhead{padding:var(--s4) var(--s5) 0;background:var(--panel)}
          .objhead .idl{display:flex;align-items:center;gap:var(--s3);flex-wrap:wrap;margin-top:3px}
          .objhead h2{font-size:var(--t-xl);font-weight:600;letter-spacing:-.015em}
          .objhead .sub{font-family:var(--mono);font-size:var(--t-sm);color:var(--ink-3);margin-top:5px}
          .mrow{display:flex;gap:var(--s6);flex-wrap:wrap;padding:var(--s4) 0 var(--s3)}
          .acts{display:flex;gap:var(--s2);flex-wrap:wrap;align-items:center;padding-bottom:var(--s4)}
          .tabsrow{display:flex;gap:var(--s1);padding:0 var(--s5);background:var(--panel);
            border-bottom:1px solid var(--line);flex:0 0 auto}
          .tabsrow a{padding:var(--s3) var(--s4);font-size:var(--t-md);color:var(--ink-3);
            border-bottom:2px solid transparent;margin-bottom:-1px}
          .tabsrow a[aria-current="page"]{color:var(--ink);font-weight:500;border-bottom-color:var(--accent)}
          .body{padding:var(--s5) var(--s5) 70px;overflow:auto;flex:1}
          .sect{margin-bottom:var(--s6)}
          .sect>h3{font-size:var(--t-sm);letter-spacing:.1em;text-transform:uppercase;
            color:var(--ink-3);font-weight:600;margin-bottom:var(--s3);
            display:flex;align-items:center;gap:var(--s3)}
          .sect>h3 .hint{margin-left:auto;font-size:var(--t-sm);letter-spacing:0;
            text-transform:none;color:var(--ink-3);font-weight:400}

          /* -------- rows -------- */
          .rows{border:1px solid var(--line);border-radius:var(--r2);overflow:hidden;background:var(--panel)}
          .row{display:grid;align-items:center;gap:var(--s4);padding:var(--s3) var(--s4);width:100%;
            border-bottom:1px solid var(--line-soft);font-size:var(--t-md)}
          .row:last-child{border-bottom:0}
          a.row:hover,button.row:hover{background:var(--panel-2)}
          .row .nm{font-weight:500;overflow:hidden;text-overflow:ellipsis}
          .row .dim{color:var(--ink-3);font-family:var(--mono);font-size:var(--t-sm)}
          .empty{padding:var(--s6);text-align:center;color:var(--ink-3);font-size:var(--t-md)}
          .kv{display:grid;grid-template-columns:140px minmax(0,1fr);gap:7px var(--s4);
            font-size:var(--t-md);margin:0}
          .kv dt{color:var(--ink-3)}
          .kv dd{margin:0;font-family:var(--mono);word-break:break-word}
          .rel{display:flex;flex-direction:column;gap:1px;background:var(--line);
            border:1px solid var(--line);border-radius:var(--r2);overflow:hidden}
          .rel a,.rel div{background:var(--panel);padding:var(--s3) var(--s4);display:flex;
            align-items:center;gap:var(--s3);font-size:var(--t-md);width:100%}
          .rel a:hover{background:var(--panel-2)}
          .rel .verb{font-size:var(--t-xs);letter-spacing:.08em;text-transform:uppercase;
            color:var(--ink-3);min-width:86px;flex:0 0 auto}
          .factor{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,max-content);
            gap:var(--s4);padding:var(--s3) 0;border-bottom:1px solid var(--line-soft);font-size:var(--t-md)}
          .factor:last-child{border-bottom:0}
          .factor .d{color:var(--ink-3);font-family:var(--mono);font-size:var(--t-sm);text-align:right}
          pre.raw{margin:0;background:var(--stage);border:1px solid var(--line);
            border-radius:var(--r2);padding:var(--s4);font-family:var(--mono);font-size:var(--t-sm);
            line-height:1.6;overflow-x:auto;color:var(--ink-2)}
          .banner{display:flex;align-items:center;gap:var(--s3);font-size:var(--t-md);
            padding:var(--s3) var(--s4);border-radius:var(--r);margin-bottom:var(--s4)}
          .banner.warn{background:var(--warn-bg);color:var(--warn)}
          .banner.crit{background:var(--crit-bg);color:var(--crit)}
          .banner.acc{background:var(--accent-soft);color:var(--accent)}

          .flash{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);
            background:var(--panel);border:1px solid var(--line);border-radius:var(--r2);
            padding:var(--s3) var(--s5);font-size:var(--t-md);z-index:50;
            display:flex;align-items:center;gap:var(--s4);
            box-shadow:0 4px 18px rgba(0,0,0,.35)}
          .flash.err{border-color:var(--crit);color:var(--crit)}
          .flash button{color:var(--ink-3);font-size:var(--t-sm)}

          @media (max-width:1000px){
            .console{grid-template-columns:1fr;height:auto}
            .tree{border-right:0;border-bottom:1px solid var(--line)}
            .icons{flex-direction:row;justify-content:flex-start;padding:var(--s2) var(--s3)}
            .icons .spacer{margin-top:0;margin-left:auto}
          }
          @media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
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
