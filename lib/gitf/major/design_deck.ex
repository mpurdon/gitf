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

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(mission_title(mission))} — design decision</title>
    <style>#{css()}</style></head><body>
    <div class="deck">#{Enum.join(slides, "\n")}</div>
    <div class="bar">
      <button onclick="go(-1)" aria-label="Previous">&#8592;</button>
      <span id="pos">1 / #{length(slides)}</span>
      <button onclick="go(1)" aria-label="Next">&#8594;</button>
      <span class="hint">arrow keys &middot; print for PDF</span>
    </div>
    <script>#{js()}</script>
    </body></html>
    """
  end

  defp title_slide(mission, report) do
    headline = report && report["headline"]

    slide("title", """
    <div class="eyebrow">Design decision &middot; #{esc(mission[:id])}</div>
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

      slide("", """
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
        [{_, first} | rest] -> Enum.reduce(rest, first, fn {_, f}, acc -> acc -- acc -- f end)
      end

    if is_nil(text) and cmp == [] do
      nil
    else
      counts =
        Enum.map_join(cmp, "", fn {s, files} ->
          "<div class=\"stat\"><b>#{length(files)}</b><span>#{esc(s)}</span></div>"
        end)

      slide("", """
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

    slide(if(won?, do: "won", else: ""), """
    <div class="eyebrow">#{esc(name)}#{if won?, do: " &middot; selected", else: ""}</div>
    <h2>#{esc(entry["character"] || "Approach: #{name}")}</h2>
    #{if bullets == "", do: "", else: "<ul class=\"points\">#{bullets}</ul>"}
    #{if risks == [], do: "", else: "<div class=\"risks\"><h3>Risks it foresaw</h3><ul>#{Enum.map_join(risks, "", &"<li>#{esc(&1)}</li>")}</ul></div>"}
    <div class="meta">#{length(Design.files(design))} files &middot; #{length(list_of(design, "components"))} components</div>
    """)
  end

  defp decision_slide(report, review) do
    text = report && report["decision"]
    selected = review && review["selected_design"]

    if is_nil(text) and is_nil(selected) do
      nil
    else
      slide("decision", """
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

      slide("", """
      <h2>Worth watching</h2>
      <p class="meta">Carried forward from the review — not blockers, but the things most likely to bite.</p>
      <ul class="watch">#{rows}</ul>
      """)
    end
  end

  defp slide(class, inner), do: "<section class=\"slide #{class}\">#{inner}</section>"

  # -- Helpers ---------------------------------------------------------------

  defp mission_title(mission) do
    case GiTF.Missions.get_artifact(mission[:id], "requirements") do
      %{"title" => t} when is_binary(t) and t != "" -> t
      _ -> mission[:name] || mission[:id]
    end
  end

  defp goal_line(mission) do
    (mission[:goal] || "") |> String.split("\n") |> List.first() |> to_string() |> String.slice(0, 160)
  end

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
    """
    :root{--bg:#f7f7f5;--ink:#16181d;--muted:#5f6672;--line:#dcdfe4;--won:#8a6a12;--ok:#1d6b45;--miss:#9a3131;--card:#fff}
    @media(prefers-color-scheme:dark){:root{--bg:#12141a;--ink:#e8eaef;--muted:#98a0ad;--line:#282d36;--won:#d9a441;--ok:#5cb686;--miss:#e2706a;--card:#181b22}}
    *{box-sizing:border-box;margin:0}
    body{background:var(--bg);color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;padding-bottom:72px}
    .deck{max-width:56rem;margin:0 auto;padding:2rem 1.25rem}
    .slide{display:none;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:2.5rem;min-height:26rem}
    .slide.on{display:block}
    .slide.won{border-color:var(--won)}
    h1{font:600 2.1rem/1.2 Georgia,"Times New Roman",serif;text-wrap:balance;margin-bottom:.75rem}
    h2{font:600 1.55rem/1.25 Georgia,"Times New Roman",serif;text-wrap:balance;margin-bottom:1rem}
    h3{font:600 .95rem/1.4 system-ui;margin:1.25rem 0 .4rem}
    .eyebrow{font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);font-weight:600;margin-bottom:.6rem}
    .lede{font-size:1.15rem;color:var(--ink);margin-bottom:1rem}
    .body{max-width:60ch;margin-bottom:1rem}
    .meta{color:var(--muted);font-size:.87rem}
    ul,ol{padding-left:1.15rem}
    .points{list-style:none;padding:0;display:flex;flex-direction:column;gap:.5rem;margin-bottom:.5rem}
    .points li{padding-left:1.4rem;position:relative}
    .saw::before{content:"✓";position:absolute;left:0;color:var(--ok);font-weight:700}
    .missed::before{content:"✗";position:absolute;left:0;color:var(--miss);font-weight:700}
    .risks ul{display:flex;flex-direction:column;gap:.35rem;font-size:.9rem;color:var(--muted)}
    .reqs li{margin-bottom:.5rem}
    .watch{list-style:none;padding:0;display:flex;flex-direction:column;gap:.9rem}
    .watch b{display:block}
    .watch span{color:var(--muted);font-size:.9rem}
    .stats{display:flex;gap:2rem;margin:1.25rem 0}
    .stat b{display:block;font-size:1.8rem;font-weight:600}
    .stat span{color:var(--muted);font-size:.8rem;text-transform:uppercase;letter-spacing:.08em}
    .bar{position:fixed;bottom:0;left:0;right:0;background:var(--card);border-top:1px solid var(--line);display:flex;align-items:center;justify-content:center;gap:1rem;padding:.75rem}
    .bar button{background:none;border:1px solid var(--line);color:var(--ink);border-radius:6px;padding:.25rem .7rem;cursor:pointer;font-size:1rem}
    .hint{color:var(--muted);font-size:.75rem}
    @media print{
      body{padding:0;background:#fff;color:#000}
      .slide{display:block!important;page-break-after:always;border:none;min-height:auto;padding:0 0 2rem}
      .bar{display:none}
    }
    """
  end

  defp js do
    """
    var s=document.querySelectorAll('.slide'),i=0;
    function show(){s.forEach(function(el,n){el.classList.toggle('on',n===i)});
      document.getElementById('pos').textContent=(i+1)+' / '+s.length;}
    function go(d){i=Math.max(0,Math.min(s.length-1,i+d));show();}
    document.addEventListener('keydown',function(e){
      if(e.key==='ArrowRight'||e.key===' ')go(1);
      if(e.key==='ArrowLeft')go(-1);});
    show();
    """
  end
end
