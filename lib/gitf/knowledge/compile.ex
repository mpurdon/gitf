defmodule GiTF.Knowledge.Compile do
  @moduledoc """
  Post-merge wiki compilation: extracts entity pages from a successful
  mission and folds them into the sector's vault.

  This is where the wiki *compounds*. Every clean merge produces fresh
  knowledge — the design doc explains what was built, the goal explains
  why, the diff shows what changed. We ask an LLM to distil this into
  one to three Karpathy-style entity pages and (optionally) update the
  sector's curated indexes.

  ## When it runs

  Triggered from `GiTF.Outcomes.Tracker.fire_terminal_feedback/1` for
  outcomes whose `outcome_category` is `:merged_clean`. The call runs in
  a `Task.Supervisor.start_child/2` so a slow LLM never stalls the poll
  stream.

  Gated by `:knowledge_compile_enabled` (default false). Disabled =
  no-op.

  ## Idempotence

  Pages are addressed by `{sector_id, slug}`. Re-running compile for the
  same mission produces the same slug → `Page.put/1` updates rather than
  duplicates. Index entry insertion deduplicates by slug.

  ## LLM contract

  The compiler prompts the LLM for a strict JSON envelope:

      {
        "pages": [
          {"slug": "auth-flow", "title": "Auth Flow",
           "body": "markdown body…", "tags": ["auth", "security"]}
        ],
        "index_updates": [
          {"name": "API Endpoints",
           "entry": {"slug": "auth-flow", "gloss": "OAuth2 token refresh"}}
        ]
      }

  Anything outside this shape is ignored. Empty arrays are valid (the
  mission introduced no new wiki-worthy concept).
  """

  require Logger

  alias GiTF.Knowledge.Index
  alias GiTF.Knowledge.Page
  alias GiTF.Major.PhaseCollector
  alias GiTF.Skills.LLM

  @default_model "anthropic:claude-sonnet-4-6"
  @max_input_chars 8_000

  @doc """
  Entry point. Compiles wiki updates from a merged mission.

  Returns `:ok` regardless of LLM outcome — best-effort.
  """
  @spec compile_after_merge(map(), map()) :: :ok
  def compile_after_merge(mission, outcome) when is_map(mission) and is_map(outcome) do
    cond do
      not enabled?() ->
        :ok

      not is_binary(mission[:sector_id]) ->
        Logger.debug("Knowledge.Compile: mission #{mission[:id]} has no sector, skipping")
        :ok

      true ->
        do_compile(mission, outcome)
    end
  rescue
    e ->
      Logger.warning(
        "Knowledge.Compile for mission #{inspect(Map.get(mission, :id))} raised: " <>
          Exception.message(e)
      )

      :ok
  end

  # -- Pipeline --------------------------------------------------------------

  defp do_compile(mission, outcome) do
    case run_compiler(mission, outcome) do
      {:ok, %{"pages" => pages} = payload} when is_list(pages) ->
        Enum.each(pages, &apply_page(&1, mission[:sector_id]))

        index_updates = Map.get(payload, "index_updates", [])
        if is_list(index_updates), do: Enum.each(index_updates, &apply_index_update(&1, mission[:sector_id]))

        emit_telemetry(mission, length(pages), length(index_updates(payload)))
        :ok

      {:ok, other} ->
        Logger.debug("Knowledge.Compile: ignoring unexpected payload shape: #{inspect(other)}")
        :ok

      {:error, reason} ->
        Logger.warning("Knowledge.Compile LLM failed: #{inspect(reason)}")
        :ok
    end
  end

  defp index_updates(%{"index_updates" => list}) when is_list(list), do: list
  defp index_updates(_), do: []

  # -- LLM call --------------------------------------------------------------

  defp run_compiler(mission, outcome) do
    prompt = build_prompt(mission, outcome)

    case LLM.generate_and_extract(model(), prompt) do
      {:ok, text} -> PhaseCollector.extract_json(text)
      {:error, _} = err -> err
    end
  end

  defp build_prompt(mission, outcome) do
    sector = mission[:sector_id]
    goal = LLM.truncate(mission[:goal] || "", 1_000)
    design = LLM.truncate(get_artifact(mission, "design"), 3_000)
    research = LLM.truncate(get_artifact(mission, "research"), 1_500)
    pr_url = outcome[:pr_url] || outcome["pr_url"] || "?"

    existing_slugs =
      Page.list(sector)
      |> Enum.take(40)
      |> Enum.map(& &1.slug)

    existing_indexes =
      Index.list(sector)
      |> Enum.map(& &1.name)

    """
    You are extracting durable wiki knowledge from a merged code change.
    The Factory's wiki is a Karpathy-style knowledge base of entity pages
    in markdown. Your job is to identify ONE TO THREE concepts introduced
    or significantly modified by this mission and write a compact entity
    page for each. Use existing slugs when an entity already exists.

    Output ONLY a JSON object with this exact shape:

    {
      "pages": [
        {
          "slug": "kebab-case-slug",
          "title": "Human Title",
          "body": "Markdown body. Use [[other-slug]] to link to related pages.",
          "tags": ["tag1", "tag2"]
        }
      ],
      "index_updates": [
        {"name": "Existing Index Name", "entry": {"slug": "the-page", "gloss": "one-line description"}}
      ]
    }

    Rules:
    - Pages MUST capture durable concepts (auth flows, APIs, components,
      modules, policies). Do NOT make pages about transient bugfixes.
    - Body should be 80-300 words of substantive content, not a summary
      of the PR. Reference [[wikilinks]] where relevant.
    - When the mission genuinely introduces no new wiki-worthy concept,
      return {"pages": [], "index_updates": []}.
    - When suggesting an index update, the index `name` MUST match an
      existing one from the list below.

    SECTOR: #{sector}
    PR: #{pr_url}
    GOAL: #{goal}

    EXISTING PAGE SLUGS (use these when extending an entity):
    #{Enum.join(existing_slugs, ", ")}

    EXISTING INDEXES:
    #{Enum.join(existing_indexes, ", ")}

    RESEARCH ARTIFACT:
    #{research}

    DESIGN ARTIFACT:
    #{design}

    Return JSON only.
    """
    |> LLM.truncate(@max_input_chars)
  end

  defp get_artifact(mission, name) do
    case GiTF.Missions.get_artifact(mission[:id], name) do
      nil -> ""
      %{} = a -> a[:body] || a["body"] || a[:summary] || a["summary"] || inspect(a)
      s when is_binary(s) -> s
      other -> inspect(other)
    end
  rescue
    _ -> ""
  end

  # -- Page application ------------------------------------------------------

  defp apply_page(%{"slug" => slug, "body" => body} = p, sector_id)
       when is_binary(slug) and is_binary(body) do
    title = p["title"] || slug
    tags = p["tags"] || []

    case Page.put(%{
           slug: slug,
           sector_id: sector_id,
           title: title,
           body: body,
           tags: tags
         }) do
      {:ok, _page} ->
        Logger.info("Knowledge.Compile: applied page #{slug} in #{sector_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Knowledge.Compile: page #{slug} failed: #{inspect(reason)}")
    end
  end

  defp apply_page(other, _sector_id) do
    Logger.debug("Knowledge.Compile: skipping malformed page entry #{inspect(other)}")
    :ok
  end

  # -- Index update application ----------------------------------------------

  defp apply_index_update(%{"name" => name, "entry" => entry}, sector_id)
       when is_binary(name) and is_map(entry) do
    case Index.get(sector_id, name) do
      nil ->
        Logger.debug(
          "Knowledge.Compile: index '#{name}' not found in #{sector_id}, skipping update"
        )

        :ok

      idx ->
        slug = entry["slug"]
        gloss = entry["gloss"] || ""

        if is_binary(slug) and slug != "" do
          merge_index_entry(idx, slug, gloss)
        end
    end
  end

  defp apply_index_update(_, _), do: :ok

  defp merge_index_entry(idx, slug, gloss) do
    body = read_index_body(idx)
    new_line = "- [[#{slug}]]" <> if(gloss != "", do: " — #{gloss}", else: "")

    if String.contains?(body, "[[#{slug}]]") do
      :ok
    else
      new_body = String.trim_trailing(body) <> "\n" <> new_line <> "\n"
      Index.put(%{name: idx.name, sector_id: idx.sector_id, body: new_body})
      :ok
    end
  end

  defp read_index_body(idx) do
    case File.read(idx.file_path) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  # -- Telemetry / config ----------------------------------------------------

  defp emit_telemetry(mission, page_count, index_count) do
    GiTF.Telemetry.emit([:gitf, :knowledge, :compile], %{pages: page_count, indexes: index_count}, %{
      mission_id: mission[:id],
      sector_id: mission[:sector_id]
    })
  rescue
    _ -> :ok
  end

  defp enabled?, do: Application.get_env(:gitf, :knowledge_compile_enabled, false) == true

  defp model do
    Application.get_env(:gitf, :knowledge_compile_model, @default_model)
  end
end
