defmodule GiTF.Major.DesignDeck do
  @moduledoc """
  Renders a mission's design decision as a self-contained HTML deck.

  The dashboard is tailnet-only, so a link to it is useless to anyone who
  is not on the tailnet — which is most of the people who might want to see
  why the factory built something the way it did. A single file with no
  external assets can be attached to a message and opened anywhere, which a
  URL cannot, and a PDF can do too but without staying readable, searchable
  or diffable.

  This is a *renderer*, not a second synthesis: everything on the slides
  already exists as artifacts. `GiTF.Major.DesignReport` supplies the
  argument (headline, convergence, per-strategy character, decision, watch
  items) and the design artifacts supply the evidence (files claimed, risks
  foreseen). Nothing here calls a model.

  Degrades rather than refusing: a mission with designs but no brief renders
  the evidence slides alone, which is still worth sending.
  """

  alias GiTF.Phases.Design

  @strategies ["minimal", "normal", "complex"]

  @doc """
  Builds the deck. Returns `{:ok, html}` or `{:error, :nothing_to_show}`
  when the mission has neither designs nor a brief.
  """
  @spec render(String.t()) :: {:ok, String.t()} | {:error, :nothing_to_show}
  def render(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id) do
      designs =
        for s <- @strategies,
            a = GiTF.Missions.get_artifact(mission_id, "design_#{s}"),
            is_map(a),
            do: {s, a}

      report = GiTF.Missions.get_artifact(mission_id, "design_report")
      review = GiTF.Missions.get_artifact(mission_id, "review")

      if designs == [] and not is_map(report) do
        {:error, :nothing_to_show}
      else
        {:ok, html(mission, designs, report, review)}
      end
    end
  end

  @doc "Filename for the download, stable per mission."
  @spec filename(String.t()) :: String.t()
  def filename(mission_id), do: "#{mission_id}-design-decision.html"

  # -- Rendering -------------------------------------------------------------

  defp html(mission, designs, report, review) do
    slides =
      [
        title_slide(mission, report),
        question_slide(mission),
        convergence_slide(report, designs)
      ] ++
        Enum.map(designs, &strategy_slide(&1, report, review)) ++
        [decision_slide(report, review), watch_slide(report)]

    slides = Enum.reject(slides, &is_nil/1)
    total = length(slides)

    {sections, rail} =
      slides
      |> Enum.with_index()
      |> Enum.map(fn {{label, class, inner}, i} ->
        no = String.pad_leading("#{i + 1}", 2, "0")

        {"<section class=\"slide #{class}\" data-label=\"#{esc(label)}\">" <>
           "<div class=\"no\">#{no}</div>#{inner}</section>",
         "<button class=\"rail-item\" data-i=\"#{i}\">" <>
           "<span class=\"rail-no\">#{no}</span><span>#{esc(label)}</span></button>"}
      end)
      |> Enum.unzip()

    sections = Enum.join(sections, "\n")
    rail = Enum.join(rail, "\n")

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(mission_title(mission))} — design decision</title>
    <style>#{css()}</style></head><body>
    <div class="prog"><div id="progfill"></div></div>
    <div class="frame">
      <nav class="rail" aria-label="Contents">
        <div class="rail-head">Contents</div>
        #{rail}
      </nav>
      <main class="deck">#{sections}</main>
    </div>
    <div class="bar">
      <button onclick="go(-1)" aria-label="Previous">&#8592;</button>
      <span id="pos">1 / #{total}</span>
      <span id="sect" class="sect"></span>
      <button onclick="go(1)" aria-label="Next">&#8594;</button>
      <span class="hint">arrow keys &middot; print for PDF</span>
    </div>
    <script>#{js()}</script>
    </body></html>
    """
  end

  defp title_slide(mission, report) do
    headline = report && report["headline"]

    slide("Cover", "title", """
    <div class="eyebrow">Design decision &middot; <span class="mono">#{esc(mission[:id])}</span></div>
    <h1>#{esc(mission_title(mission))}</h1>
    #{if headline, do: "<p class=\"lede\">#{esc(headline)}</p>", else: ""}
    <p class="meta">#{esc(goal_line(mission))}</p>
    """)
  end

  defp question_slide(mission) do
    reqs = GiTF.Missions.get_artifact(mission[:id], "requirements")
    functional = list_of(reqs, "functional_requirements")

    if functional == [] do
      nil
    else
      items =
        functional
        |> Enum.take(8)
        |> Enum.map_join("", fn r ->
          "<li><b>#{esc(r["id"])}</b> #{esc(r["description"])}</li>"
        end)

      slide("The ask", "", """
      <h2>What was asked for</h2>
      <ol class="reqs">#{items}</ol>
      """)
    end
  end

  defp convergence_slide(report, designs) do
    text = report && report["convergence"]

    cmp =
      designs
      |> Enum.map(fn {s, d} -> {s, Design.files(d)} end)

    shared =
      case cmp do
        [] -> []
        [{_, first} | rest] -> Enum.reduce(rest, first, fn {_, f}, acc -> acc -- (acc -- f) end)
      end

    if is_nil(text) and cmp == [] do
      nil
    else
      counts =
        Enum.map_join(cmp, "", fn {s, files} ->
          "<div class=\"stat\"><b>#{length(files)}</b><span>#{esc(s)}</span></div>"
        end)

      slide("Convergence", "", """
      <h2>Did they actually differ?</h2>
      #{if text, do: "<p class=\"body\">#{esc(text)}</p>", else: ""}
      <div class="stats">#{counts}</div>
      <p class="meta">#{length(shared)} file#{if length(shared) == 1, do: "", else: "s"} named by every design.</p>
      """)
    end
  end

  defp strategy_slide({name, design}, report, review) do
    entry =
      report
      |> list_of("designs")
      |> Enum.find(%{}, &(&1["strategy"] == name))

    won? = review && review["selected_design"] == name
    risks = list_of(design, "risks") |> Enum.take(4)

    bullets =
      Enum.map_join(List.wrap(entry["notable"]), "", &"<li class=\"saw\">#{esc(&1)}</li>") <>
        Enum.map_join(List.wrap(entry["missed"]), "", &"<li class=\"missed\">#{esc(&1)}</li>")

    slide(name, if(won?, do: "won", else: ""), """
    #{if won?, do: "<div class=\"stamp\" aria-hidden=\"true\">Selected</div>", else: ""}
    <div class="eyebrow">Approach &middot; #{esc(name)}</div>
    <h2>#{esc(entry["character"] || "Approach: #{name}")}</h2>
    #{if bullets == "", do: "", else: "<ul class=\"points\">#{bullets}</ul>"}
    #{if risks == [], do: "", else: "<div class=\"risks\"><h3>Risks it foresaw</h3><ul>#{Enum.map_join(risks, "", &"<li>#{esc(&1)}</li>")}</ul></div>"}
    <div class="meta">#{count(length(Design.files(design)), "file")} &middot; #{count(length(list_of(design, "components")), "component")}</div>
    """)
  end

  defp decision_slide(report, review) do
    text = report && report["decision"]
    selected = review && review["selected_design"]

    if is_nil(text) and is_nil(selected) do
      nil
    else
      slide("Decision", "decision", """
      <div class="eyebrow">The decision</div>
      <h2>#{esc(selected || "—")}</h2>
      #{if text, do: "<p class=\"body\">#{esc(text)}</p>", else: ""}
      #{if review && review["approved"] == true, do: "<p class=\"meta\">Approved by review.</p>", else: ""}
      """)
    end
  end

  defp watch_slide(report) do
    items = list_of(report, "watch_items")

    if items == [] do
      nil
    else
      rows =
        Enum.map_join(items, "", fn w ->
          "<li><b>#{esc(w["concern"])}</b><span>#{esc(w["why_it_matters"])}</span></li>"
        end)

      slide("Watch list", "", """
      <h2>Worth watching</h2>
      <p class="meta">Carried forward from the review — not blockers, but the things most likely to bite.</p>
      <ul class="watch">#{rows}</ul>
      """)
    end
  end

  defp slide(label, class, inner), do: {label, class, inner}

  # -- Helpers ---------------------------------------------------------------

  defp mission_title(mission) do
    case GiTF.Missions.get_artifact(mission[:id], "requirements") do
      %{"title" => t} when is_binary(t) and t != "" -> t
      _ -> mission[:name] || mission[:id]
    end
  end

  defp goal_line(mission) do
    (mission[:goal] || "")
    |> String.split("\n")
    |> List.first()
    |> to_string()
    |> String.slice(0, 160)
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp list_of(nil, _key), do: []

  defp list_of(map, key) when is_map(map) do
    case Map.get(map, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  defp list_of(_, _), do: []

  # Everything rendered comes from model output, so it is escaped without
  # exception — a stray angle bracket in a risk description must not be able
  # to restructure the page.
  defp esc(nil), do: ""

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp css do
    # One committed look — technical paper and ink, inspection-stamp blue as
    # the only accent — because this file is a document: it should read on
    # screen exactly as it prints. Headings are heavy sans, body is Charter
    # serif, ids and counts are mono; the left rail is the table of contents
    # and the SELECTED stamp is the one loud thing on the page.
    """
    :root{--paper:#f4f2ec;--card:#fffefa;--ink:#1c1e21;--muted:#6c6f76;--rule:#ddd9cf;
      --stamp:#2b4d8f;--stamp-soft:#e7ecf6;--ok:#206b48;--miss:#9b3434}
    *{box-sizing:border-box;margin:0}
    html{scroll-behavior:smooth}
    body{background:var(--paper);color:var(--ink);
      font:16px/1.65 Charter,Georgia,"Times New Roman",serif;padding-bottom:76px}
    .mono{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:.92em}
    .prog{position:fixed;top:0;left:0;right:0;height:3px;background:var(--rule);z-index:3}
    #progfill{height:100%;width:0;background:var(--stamp);transition:width .25s ease}
    .frame{display:flex;gap:2rem;max-width:72rem;margin:0 auto;padding:2.5rem 1.5rem 1rem}

    .rail{flex:0 0 13rem;position:sticky;top:2.5rem;align-self:flex-start;
      display:flex;flex-direction:column;gap:2px}
    .rail-head{font:700 .68rem/1 system-ui;letter-spacing:.16em;text-transform:uppercase;
      color:var(--muted);padding:0 .6rem .6rem;border-bottom:1px solid var(--rule);margin-bottom:.4rem}
    .rail-item{display:flex;gap:.6rem;align-items:baseline;text-align:left;width:100%;
      background:none;border:none;border-left:2px solid transparent;cursor:pointer;
      padding:.32rem .6rem;color:var(--muted);
      font:500 .85rem/1.35 system-ui,-apple-system,"Segoe UI",sans-serif}
    .rail-item .rail-no{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
      font-size:.7rem;color:var(--muted);opacity:.7}
    .rail-item:hover{color:var(--ink)}
    .rail-item.on{color:var(--ink);border-left-color:var(--stamp);background:var(--stamp-soft);font-weight:600}
    .rail-item.on .rail-no{color:var(--stamp);opacity:1}

    .deck{flex:1;min-width:0}
    .slide{display:none;position:relative;background:var(--card);border:1px solid var(--rule);
      border-radius:4px;padding:3rem 3rem 2.5rem;min-height:28rem;
      box-shadow:0 1px 0 var(--rule),0 12px 32px -24px rgba(28,30,33,.35)}
    .slide.on{display:block;animation:rise .24s ease}
    @keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
    @media(prefers-reduced-motion:reduce){.slide.on{animation:none}#progfill{transition:none}}
    .slide.won{border-color:var(--stamp)}
    .no{position:absolute;top:1.1rem;right:1.25rem;
      font:600 .72rem/1 ui-monospace,"SF Mono",Menlo,Consolas,monospace;color:var(--muted)}

    .stamp{position:absolute;top:2.2rem;right:2.4rem;transform:rotate(-6deg);
      font:800 .8rem/1 system-ui;letter-spacing:.22em;text-transform:uppercase;
      color:var(--stamp);border:3px double var(--stamp);border-radius:4px;
      padding:.45rem .8rem .4rem;opacity:.85}

    h1{font:800 2.8rem/1.12 system-ui,-apple-system,"Segoe UI",sans-serif;
      letter-spacing:-.02em;text-wrap:balance;margin-bottom:1rem}
    .slide.title.on{display:flex;flex-direction:column;justify-content:center}
    h2{font:750 1.6rem/1.2 system-ui,-apple-system,"Segoe UI",sans-serif;
      letter-spacing:-.015em;text-wrap:balance;margin-bottom:1rem}
    h3{font:700 .8rem/1.4 system-ui;letter-spacing:.1em;text-transform:uppercase;
      color:var(--muted);margin:1.5rem 0 .5rem}
    .eyebrow{font:700 .7rem/1 system-ui;letter-spacing:.16em;text-transform:uppercase;
      color:var(--stamp);margin-bottom:.9rem}
    .lede{font-size:1.2rem;line-height:1.5;font-style:italic;margin-bottom:1.1rem;max-width:36rem}
    .body{max-width:60ch;margin-bottom:1rem}
    .meta{color:var(--muted);font-size:.87rem;margin-top:.75rem}
    ul,ol{padding-left:1.15rem}

    .points{list-style:none;padding:0;display:flex;flex-direction:column;gap:.55rem;margin-bottom:.5rem}
    .points li{padding-left:1.5rem;position:relative}
    .saw::before{content:"✓";position:absolute;left:0;color:var(--ok);font-weight:700}
    .missed::before{content:"✗";position:absolute;left:0;color:var(--miss);font-weight:700}
    .risks{border-left:2px solid var(--rule);padding-left:1rem;margin-top:1.25rem}
    .risks ul{display:flex;flex-direction:column;gap:.4rem;font-size:.92rem;color:var(--muted)}
    .reqs li{margin-bottom:.55rem}
    .reqs b{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:.8rem;
      color:var(--stamp);font-weight:600;margin-right:.3rem}
    .watch{list-style:none;padding:0;display:flex;flex-direction:column;gap:1rem}
    .watch li{border-left:2px solid var(--rule);padding-left:1rem}
    .watch b{display:block;font-family:system-ui;font-weight:650}
    .watch span{color:var(--muted);font-size:.92rem}
    .stats{display:flex;gap:2.5rem;margin:1.5rem 0 .5rem}
    .stat b{display:block;font:700 2.1rem/1.1 ui-monospace,"SF Mono",Menlo,Consolas,monospace}
    .stat span{color:var(--muted);font:600 .72rem/1.6 system-ui;text-transform:uppercase;letter-spacing:.1em}
    .decision h2{font-size:2rem;color:var(--stamp)}

    .bar{position:fixed;bottom:0;left:0;right:0;background:var(--card);
      border-top:1px solid var(--rule);display:flex;align-items:center;
      justify-content:center;gap:1rem;padding:.7rem;z-index:3}
    .bar button{background:none;border:1px solid var(--rule);color:var(--ink);
      border-radius:4px;padding:.25rem .7rem;cursor:pointer;font-size:1rem}
    .bar button:hover{border-color:var(--stamp);color:var(--stamp)}
    #pos{font:600 .8rem/1 ui-monospace,"SF Mono",Menlo,Consolas,monospace}
    .sect{font:600 .8rem/1 system-ui;color:var(--muted)}
    .hint{color:var(--muted);font-size:.72rem;font-family:system-ui}

    @media(max-width:52rem){
      .frame{flex-direction:column;gap:1.25rem;padding-top:1.5rem}
      .rail{position:static;flex-direction:row;flex-wrap:wrap;flex-basis:auto;gap:.35rem}
      .rail-head{display:none}
      .rail-item{width:auto;border:1px solid var(--rule);border-radius:999px;padding:.25rem .7rem}
      .rail-item.on{border-color:var(--stamp)}
      .rail-item .rail-no{display:none}
      .slide{padding:1.75rem 1.5rem;min-height:auto}
      .stamp{top:1rem;right:1rem;font-size:.65rem;padding:.3rem .5rem}
      .sect{display:none}
    }
    @media print{
      body{padding:0;background:#fff}
      .prog,.rail,.bar{display:none}
      .frame{display:block;max-width:none;padding:0}
      .slide{display:block!important;page-break-after:always;border:none;box-shadow:none;
        min-height:auto;padding:0 0 2.5rem;animation:none}
      .stamp{position:absolute;top:0;right:0}
    }
    """
  end

  defp js do
    """
    var s=document.querySelectorAll('.slide'),
        r=document.querySelectorAll('.rail-item'),i=0;
    function show(){
      s.forEach(function(el,n){el.classList.toggle('on',n===i)});
      r.forEach(function(el,n){el.classList.toggle('on',n===i)});
      document.getElementById('pos').textContent=(i+1)+' / '+s.length;
      document.getElementById('sect').textContent=s[i].getAttribute('data-label')||'';
      document.getElementById('progfill').style.width=(100*(i+1)/s.length)+'%';
      history.replaceState(null,'','#'+(i+1));
    }
    function go(d){i=Math.max(0,Math.min(s.length-1,i+d));show();}
    function jump(n){i=Math.max(0,Math.min(s.length-1,n));show();}
    var h=parseInt(location.hash.slice(1),10);
    if(h>=1&&h<=s.length)i=h-1;
    r.forEach(function(el){el.addEventListener('click',function(){jump(+el.getAttribute('data-i'))})});
    document.addEventListener('keydown',function(e){
      if(e.key==='ArrowRight'||e.key===' '||e.key==='PageDown')go(1);
      if(e.key==='ArrowLeft'||e.key==='PageUp')go(-1);
      if(e.key==='Home')jump(0);
      if(e.key==='End')jump(s.length-1);});
    show();
    """
  end
end
