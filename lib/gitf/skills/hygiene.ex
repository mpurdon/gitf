defmodule GiTF.Skills.Hygiene do
  @moduledoc """
  Periodic maintenance for the skill library. Runs daily via `GiTF.Cron`.

  Compaction actions:

    * **Demote low-utility skills** — any skill with `applied_count > N`
      and `success_rate < threshold` gets `status: :archived`. Archived
      skills are excluded from retrieval but retained for audit and
      potential manual un-archive.
    * **Detect near-duplicates** — pairs of active skills with cosine
      similarity > threshold are flagged. The older skill wins; the
      newer one is archived with a pointer to the winner.
    * **Enforce per-sector cap** — if an active pool exceeds the cap,
      archive the lowest-utility skills until under cap.

  All state mutations go through `Skills.update/2` (atomic). Hygiene
  never deletes skills — archival only, so nothing is lost.
  """

  require Logger

  alias GiTF.Skills
  alias GiTF.Skills.Embedding

  @doc """
  Returns options with computed thresholds. Config overrides:

    * `:skill_hygiene_min_applies` — default 20
    * `:skill_hygiene_min_success_rate` — default 0.3
    * `:skill_hygiene_duplicate_threshold` — default 0.95
    * `:skill_hygiene_per_sector_cap` — default 50
  """
  @spec thresholds() :: map()
  def thresholds do
    %{
      min_applies: Application.get_env(:gitf, :skill_hygiene_min_applies, 20),
      min_success_rate: Application.get_env(:gitf, :skill_hygiene_min_success_rate, 0.3),
      duplicate_threshold: Application.get_env(:gitf, :skill_hygiene_duplicate_threshold, 0.95),
      per_sector_cap: Application.get_env(:gitf, :skill_hygiene_per_sector_cap, 50)
    }
  end

  @doc """
  Runs a full compaction pass. Returns a map of counts per action for
  operators and telemetry.
  """
  @spec compact() :: %{demoted: non_neg_integer(), deduped: non_neg_integer(), capped: non_neg_integer()}
  def compact do
    t = thresholds()

    demoted = demote_low_utility(t)
    deduped = dedupe(t)
    capped = enforce_cap(t)

    summary = %{demoted: demoted, deduped: deduped, capped: capped}

    if demoted + deduped + capped > 0 do
      Logger.info("Skills.Hygiene: compaction pass — #{inspect(summary)}")
    end

    summary
  rescue
    e ->
      Logger.warning("Skills.Hygiene.compact raised: #{Exception.message(e)}")
      %{demoted: 0, deduped: 0, capped: 0}
  end

  # -- Demotion ----------------------------------------------------------------

  defp demote_low_utility(%{min_applies: min_applies, min_success_rate: min_rate}) do
    active = Skills.all() |> Enum.filter(&(&1.status == :active))

    Enum.reduce(active, 0, fn skill, count ->
      if low_utility?(skill, min_applies, min_rate) do
        archive!(skill, "low_utility: #{skill.applied_count} applies, #{success_rate(skill)} success")
        count + 1
      else
        count
      end
    end)
  end

  defp low_utility?(skill, min_applies, min_rate) do
    skill.applied_count >= min_applies and success_rate(skill) < min_rate
  end

  defp success_rate(%{success_count: s, failure_count: f}) do
    total = s + f
    if total == 0, do: 1.0, else: s / total
  end

  # -- Deduplication -----------------------------------------------------------

  defp dedupe(%{duplicate_threshold: threshold}) do
    active =
      Skills.all()
      |> Enum.filter(fn s ->
        s.status == :active and is_list(s.embedding) and s.embedding != []
      end)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    # Group by scope (global + per-sector) so we don't cross-compare
    # skills that belong to different pools.
    active
    |> Enum.group_by(&{&1.scope, &1.sector_id})
    |> Enum.reduce(0, fn {_key, skills}, count ->
      count + dedupe_group(skills, threshold)
    end)
  end

  defp dedupe_group(skills, threshold) do
    # O(n^2) pairwise compare — fine for realistic pool sizes (<500).
    pairs =
      for {older, i} <- Enum.with_index(skills),
          {newer, j} <- Enum.with_index(skills),
          i < j,
          sim = Embedding.cosine(older.embedding, newer.embedding),
          sim >= threshold,
          do: {older, newer, sim}

    pairs
    |> Enum.uniq_by(fn {_, newer, _} -> newer.id end)
    |> Enum.reduce(0, fn {older, newer, sim}, count ->
      # Only archive if both are still active (earlier pass may have
      # archived one already).
      newer_live = Skills.get(newer.id)

      if newer_live && newer_live.status == :active do
        archive!(newer_live, "duplicate of #{older.id} (cosine=#{Float.round(sim, 3)})")
        count + 1
      else
        count
      end
    end)
  end

  # -- Per-sector cap ----------------------------------------------------------

  defp enforce_cap(%{per_sector_cap: cap}) do
    # Cap applies separately to global pool and each sector pool.
    active = Skills.all() |> Enum.filter(&(&1.status == :active))

    active
    |> Enum.group_by(&{&1.scope, &1.sector_id})
    |> Enum.reduce(0, fn {_key, skills}, count ->
      if length(skills) > cap do
        to_archive =
          skills
          |> Enum.sort_by(&utility_score/1, :asc)
          |> Enum.take(length(skills) - cap)

        Enum.each(to_archive, fn s ->
          archive!(s, "over per-sector cap (#{length(skills)} > #{cap})")
        end)

        count + length(to_archive)
      else
        count
      end
    end)
  end

  # Composite score: success rate weighted by applied_count, so a high
  # success rate on 2 applies doesn't beat a mature skill with 50 applies
  # at 60% success.
  defp utility_score(skill) do
    rate = success_rate(skill)
    applies = skill.applied_count
    # Wilson-lite: pull untested skills toward 0.5 so they're not auto-dropped
    if applies < 5, do: 0.5, else: rate * :math.log(applies + 1)
  end

  # -- Archival helper ---------------------------------------------------------

  defp archive!(skill, reason) do
    Skills.update(skill.id, fn s ->
      s
      |> Map.put(:status, :archived)
      |> Map.put(:archived_reason, reason)
    end)
  rescue
    e ->
      Logger.debug("Skills.Hygiene: archive! failed for #{skill.id}: #{Exception.message(e)}")
      :ok
  end
end
