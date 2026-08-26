defmodule GiTF.Knowledge.Ingest.URL do
  @moduledoc """
  Ingests a web page (and optionally same-host links one hop deep) as
  `GiTF.Knowledge.Page` records.

  ## Pipeline

      Req.get → Floki.parse_document → strip nav/script/style →
      extract title → html_to_markdown → Knowledge.Page.put

  The HTML-to-markdown conversion is intentionally small (handles the
  block-level tags that show up in real-world docs: h1-h6, p, ul/ol/li,
  pre/code, blockquote, hr, a, em/strong/code/del). Pages that depend on
  client-side JS for content rendering won't ingest cleanly — operators
  should pre-render those with a headless browser before piping through
  here.

  ## Slug

  Derived from the URL: `host_path-segments`. `https://hex.pm/docs/usage`
  → `hex-pm_docs-usage`. Trailing slashes and `.html` extensions are
  stripped. Operators can override via `:slug` opt.

  ## Crawl depth

  `depth: 0` (default) ingests only the given URL. `depth: 1` follows
  same-host links found in the rendered page, one hop deep, deduped by
  URL. Larger depths are intentionally not supported — bulk-importing
  a vendor site is a job for a dedicated scraper, not the Factory.
  """

  require Logger

  alias GiTF.Knowledge.Page

  @default_timeout_ms 15_000
  @max_pages_per_crawl 50

  @type ingest_result :: %{
          ingested: [{String.t(), String.t()}],
          skipped: [{String.t(), term()}],
          errors: [{String.t(), term()}]
        }

  @doc """
  Fetches `url`, converts to markdown, upserts as a `Knowledge.Page` in
  `sector_id`.

  Options:

    * `:slug` — explicit slug; default derived from URL
    * `:title` — explicit title; default from `<title>` or first `<h1>`
    * `:tags` — extra tags applied to the page
    * `:depth` — follow same-host links one hop deep (0 or 1, default 0)
    * `:timeout_ms` — Req fetch timeout (default 15_000)
    * `:dry_run` — fetch + convert, log what would happen, write nothing
  """
  @spec ingest(String.t(), String.t() | nil, keyword()) :: ingest_result()
  def ingest(url, sector_id, opts \\ []) when is_binary(url) do
    depth = Keyword.get(opts, :depth, 0) |> clamp_depth()
    visited = MapSet.new([canonical(url)])

    do_crawl([url], sector_id, depth, opts, visited, %{
      ingested: [],
      ingested_count: 0,
      skipped: [],
      errors: []
    })
    |> Map.delete(:ingested_count)
  end

  defp clamp_depth(d) when is_integer(d) and d >= 0 and d <= 1, do: d
  defp clamp_depth(_), do: 0

  defp do_crawl([], _sector, _depth, _opts, _visited, acc), do: acc

  defp do_crawl(_queue, _sector, _depth, _opts, _visited, %{ingested_count: n} = acc)
       when n >= @max_pages_per_crawl,
       do: %{acc | skipped: [{:crawl_cap, "hit #{@max_pages_per_crawl}-page cap"} | acc.skipped]}

  defp do_crawl([url | rest], sector_id, depth, opts, visited, acc) do
    case fetch(url, opts) do
      {:ok, html, final_url} ->
        case render(html, final_url, sector_id, opts) do
          {:ok, slug, links} ->
            new_queue = if depth > 0, do: queue_links(links, visited), else: []
            visited = Enum.reduce(new_queue, visited, &MapSet.put(&2, canonical(&1)))

            acc = %{
              acc
              | ingested: [{url, slug} | acc.ingested],
                ingested_count: acc.ingested_count + 1
            }

            do_crawl(rest ++ new_queue, sector_id, depth, opts, visited, acc)

          {:skip, reason} ->
            do_crawl(rest, sector_id, depth, opts, visited, %{
              acc
              | skipped: [{url, reason} | acc.skipped]
            })

          {:error, reason} ->
            do_crawl(rest, sector_id, depth, opts, visited, %{
              acc
              | errors: [{url, reason} | acc.errors]
            })
        end

      {:error, reason} ->
        do_crawl(rest, sector_id, depth, opts, visited, %{
          acc
          | errors: [{url, reason} | acc.errors]
        })
    end
  end

  # -- Fetch -----------------------------------------------------------------

  defp fetch(url, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Req.get(url, receive_timeout: timeout, redirect: true) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        # Req.Response doesn't carry the post-redirect URL; the originally
        # requested URL is "close enough" for slug derivation. Operators
        # can override via `:slug` if it matters.
        {:ok, ensure_string(body), url}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp ensure_string(body) when is_binary(body), do: body
  defp ensure_string(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp ensure_string(_), do: ""

  # -- Render + persist ------------------------------------------------------

  defp render(html, final_url, sector_id, opts) do
    case Floki.parse_document(html) do
      {:ok, tree} ->
        cleaned = strip_noise(tree)
        title = Keyword.get(opts, :title) || extract_title(cleaned, final_url)
        slug = Keyword.get(opts, :slug) || slug_from_url(final_url)
        markdown = html_to_markdown(cleaned)
        tags = ["url" | List.wrap(Keyword.get(opts, :tags, []))]
        body = "Source: #{final_url}\n\n" <> markdown
        links = same_host_links(cleaned, final_url)

        if Keyword.get(opts, :dry_run, false) do
          Logger.info(
            "Knowledge.Ingest.URL [dry]: would ingest #{slug} (#{title}) from #{final_url}"
          )

          {:ok, slug, links}
        else
          case Page.put(%{
                 slug: slug,
                 sector_id: sector_id,
                 title: title,
                 body: body,
                 tags: tags
               }) do
            {:ok, _} -> {:ok, slug, links}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:skip, {:parse_failed, reason}}
    end
  end

  # Strip the structural noise that doesn't survive markdown well:
  # scripts, styles, nav, footer, aside, header (often nav + branding).
  # We DO keep <main> / <article> if present.
  defp strip_noise(tree) do
    Floki.traverse_and_update(tree, fn
      {tag, _attrs, _children}
      when tag in [
             "script",
             "style",
             "nav",
             "footer",
             "aside",
             "header",
             "noscript",
             "iframe",
             "svg"
           ] ->
        nil

      other ->
        other
    end)
  end

  defp extract_title(tree, fallback_url) do
    cond do
      title = first_text(Floki.find(tree, "title")) ->
        title |> String.trim() |> truncate(200)

      title = first_text(Floki.find(tree, "h1")) ->
        title |> String.trim() |> truncate(200)

      true ->
        fallback_url |> URI.parse() |> Map.get(:host) || "Untitled"
    end
  end

  defp first_text([]), do: nil
  defp first_text([node | _]), do: node |> Floki.text() |> normalize_ws()

  defp normalize_ws(nil), do: nil
  defp normalize_ws(s), do: String.replace(s, ~r/\s+/, " ") |> String.trim()

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n)

  # -- HTML → markdown -------------------------------------------------------

  # Block-level conversion. We walk the tree depth-first; each block emits
  # a markdown line (or block) with a trailing newline. Inline tags inside
  # blocks call `inline/1` which produces a single string.
  defp html_to_markdown(tree) do
    tree
    |> Enum.flat_map(&block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp block({:doctype, _, _}), do: []
  defp block({:comment, _}), do: []
  defp block(text) when is_binary(text), do: [String.trim(text)]

  defp block({tag, _attrs, children}) when tag in ["h1", "h2", "h3", "h4", "h5", "h6"] do
    level = String.to_integer(String.last(tag))
    ["#{String.duplicate("#", level)} #{inline(children)}"]
  end

  defp block({"p", _, children}), do: [inline(children)]
  defp block({"blockquote", _, children}), do: ["> " <> inline(children)]
  defp block({"hr", _, _}), do: ["---"]

  defp block({"pre", _, children}) do
    code = children_text(children)
    lang = code_lang(children)
    fence = if lang, do: "```#{lang}", else: "```"
    ["#{fence}\n#{code}\n```"]
  end

  defp block({"ul", _, children}) do
    [
      children
      |> Enum.flat_map(fn child -> list_item("-", child) end)
      |> Enum.join("\n")
    ]
  end

  defp block({"ol", _, children}) do
    [
      children
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {child, idx} -> list_item("#{idx}.", child) end)
      |> Enum.join("\n")
    ]
  end

  defp block({"table", _, _children}) do
    # Tables are hard to render losslessly; defer to a follow-up.
    ["<!-- table omitted -->"]
  end

  # Container that just delegates to its children
  defp block({tag, _, children})
       when tag in ["html", "body", "head", "main", "article", "section", "div", "span"] do
    Enum.flat_map(children, &block/1)
  end

  # Unknown tag — render its inline content if any, otherwise drop
  defp block({_tag, _attrs, children}) do
    text = inline(children)
    if text == "", do: [], else: [text]
  end

  defp block(_), do: []

  # List items can hold inline content OR nested blocks. We render inline
  # first; nested ul/ol get indented under the parent bullet.
  defp list_item(marker, {tag, _, children}) when tag in ["li"] do
    {inline_kids, block_kids} =
      Enum.split_with(children, fn
        {t, _, _} when t in ["ul", "ol", "p", "pre", "blockquote"] -> false
        _ -> true
      end)

    head = "#{marker} #{inline(inline_kids)}"

    nested =
      block_kids
      |> Enum.flat_map(&block/1)
      |> Enum.map(&indent/1)

    [head | nested]
  end

  defp list_item(_, _), do: []

  defp indent(s), do: "  " <> String.replace(s, "\n", "\n  ")

  # -- Inline ----------------------------------------------------------------

  defp inline(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&inline_one/1)
    |> Enum.join("")
    |> normalize_inline_ws()
  end

  defp inline(node), do: inline([node])

  defp inline_one(text) when is_binary(text), do: text
  defp inline_one({"br", _, _}), do: "  \n"
  defp inline_one({"strong", _, c}), do: "**#{inline(c)}**"
  defp inline_one({"b", _, c}), do: "**#{inline(c)}**"
  defp inline_one({"em", _, c}), do: "*#{inline(c)}*"
  defp inline_one({"i", _, c}), do: "*#{inline(c)}*"
  defp inline_one({"del", _, c}), do: "~~#{inline(c)}~~"
  defp inline_one({"code", _, c}), do: "`#{children_text(c)}`"

  defp inline_one({"a", attrs, c}) do
    href = attr(attrs, "href")
    label = inline(c)

    cond do
      href in [nil, ""] -> label
      label == "" -> "<#{href}>"
      true -> "[#{label}](#{href})"
    end
  end

  defp inline_one({"img", attrs, _}) do
    src = attr(attrs, "src") || ""
    alt = attr(attrs, "alt") || ""
    "![#{alt}](#{src})"
  end

  defp inline_one({_tag, _, c}), do: inline(c)
  defp inline_one(_), do: ""

  defp normalize_inline_ws(s), do: String.replace(s, ~r/[ \t]+/, " ")

  defp attr(attrs, key) do
    Enum.find_value(attrs, fn {k, v} -> if k == key, do: v end)
  end

  defp children_text(children) do
    children
    |> Enum.map(fn
      t when is_binary(t) -> t
      {_, _, c} -> children_text(c)
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp code_lang(children) do
    Enum.find_value(children, fn
      {"code", attrs, _} ->
        case attr(attrs, "class") do
          "language-" <> lang ->
            lang

          c when is_binary(c) ->
            case Regex.run(~r/language-([\w+-]+)/, c) do
              [_, lang] -> lang
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  # -- Link discovery (depth: 1) --------------------------------------------

  defp same_host_links(tree, base_url) do
    base_host = URI.parse(base_url).host

    tree
    |> Floki.find("a[href]")
    |> Enum.map(fn {_, attrs, _} -> attr(attrs, "href") end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&resolve_url(&1, base_url))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn u -> URI.parse(u).host == base_host end)
    |> Enum.uniq()
  end

  defp resolve_url(href, base_url) do
    case URI.merge(base_url, href) do
      %URI{scheme: scheme} = u when scheme in ["http", "https"] ->
        u |> Map.put(:fragment, nil) |> URI.to_string()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp queue_links(links, visited) do
    Enum.reject(links, &MapSet.member?(visited, canonical(&1)))
  end

  defp canonical(url) do
    case URI.parse(url) do
      %URI{} = u -> u |> Map.put(:fragment, nil) |> URI.to_string()
      _ -> url
    end
  end

  # -- Slug derivation -------------------------------------------------------

  @doc """
  Builds a slug from a URL. Used by the CLI/MCP layer when the operator
  doesn't pass an explicit `:slug`. Exposed so callers can preview the
  slug before committing to ingest.
  """
  @spec slug_from_url(String.t()) :: String.t()
  def slug_from_url(url) do
    uri = URI.parse(url)
    host = (uri.host || "") |> String.replace(".", "-")

    path =
      (uri.path || "/")
      |> String.trim_trailing("/")
      |> String.trim_leading("/")
      |> String.replace(~r/\.html?$/, "")
      |> String.replace("/", "-")
      |> String.replace(~r/[^a-z0-9\-]+/i, "-")

    case {host, path} do
      {"", ""} -> "url-ingest"
      {"", p} -> p
      {h, ""} -> h
      {h, p} -> "#{h}_#{p}"
    end
    |> String.downcase()
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
