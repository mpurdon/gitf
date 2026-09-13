defmodule GiTF.Dashboard.Surface do
  @moduledoc """
  The look both surfaces are built from.

  The Cabinet Console and the Catwalk are two views of one system, and for a
  while they were two design systems: the same grey under two names
  (`--muted` here, `--ink-3` there), the same pill styled twice, the same
  five-pixel gap typed as a literal in both. Whichever you were reading, the
  other one felt like a different product.

  So the palette, the scales and the shared component styles live here, in one
  string each surface includes. What stays with a surface is what is actually
  particular to it — the Console's rail and tree, the Catwalk's own furniture.

  The vocabulary itself (`pill`, `dot`, `rows`, `object_head` …) is in
  `GiTF.Dashboard.Surface.Components`; these are the styles those components
  need, and the two travel together.
  """

  @tokens """
    :root{
      /* surfaces */
      --ground:#12161C; --stage:#0D1116; --panel:#191E26; --panel-2:#1F252E;
      /* three border weights, because the Catwalk genuinely uses three: a soft
     divider inside a panel, the standard edge, and a strong one that separates
     regions. Collapsing strong into standard is a rename that loses a role. */
  --line:#272E39; --line-soft:#212832; --line-strong:#3A4452;
      /* the rail: its ground, its resting ink, the ink when selected, and the two
     washes that mark hover and selection. `--rail-on` is ink — using it as a
     background paints white on white, which is what a rename once did. */
  --rail:#0B0F14; --rail-text:#8892A2; --rail-on:#FFFFFF;
  --rail-hover:rgba(255,255,255,.07); --rail-sel:rgba(255,255,255,.11);
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
  --shadow:0 1px 2px rgba(0,0,0,.3);
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
  """

  @components """
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
    .pill.muted{background:var(--stage);color:var(--ink-3);border-color:var(--line)}
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
    /* Two lines, then ellipsis. `sub` is a one-liner by intent, but an op's
       description is sometimes a 1,500-word prompt, and a head that grows to
       fit it stops being a head. The full text belongs in the body. */
    .objhead .sub{font-family:var(--mono);font-size:var(--t-sm);color:var(--ink-3);margin-top:5px;
      display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
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
    .row .nm,.needs .nm{font-weight:500;overflow:hidden;text-overflow:ellipsis}
    .row .dim,.needs .dim{color:var(--ink-3);font-family:var(--mono);font-size:var(--t-sm);
      overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .empty{padding:var(--s6);text-align:center;color:var(--ink-3);font-size:var(--t-md)}
    /* The body of an object page. Distinct from the Console's `.body`, which is
       a scroll container inside a fixed-height frame — on a page that sits in
       ordinary document flow that would add a nested scrollbar and 70px of air. */
    .objbody{padding-top:var(--s5)}
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
  """

  @doc """
  The design tokens and the reset.

  Every colour, space and size in either surface resolves through one of these,
  which is what makes a change to the palette a change to one line rather than
  a sweep through thirty files.
  """
  @spec tokens() :: String.t()
  def tokens, do: @tokens

  @doc "Styles for the shared component vocabulary: primitives, object frame, rows."
  @spec components() :: String.t()
  def components, do: @components

  @doc "Everything a surface needs before its own CSS: tokens, reset, components."
  @spec base() :: String.t()
  def base, do: tokens() <> "\n\n" <> components()
end
