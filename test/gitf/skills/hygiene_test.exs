defmodule GiTF.Skills.HygieneTest do
  use ExUnit.Case, async: false

  alias GiTF.Skills
  alias GiTF.Skills.Hygiene

  setup do
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    :ok
  end

  describe "demote_low_utility" do
    test "archives skills with >= min_applies and success_rate below threshold" do
      {:ok, bad} = Skills.create(%{name: "bad", description: "d", body: "b", scope: :global})
      {:ok, good} = Skills.create(%{name: "good", description: "d", body: "b", scope: :global})
      {:ok, young} = Skills.create(%{name: "young", description: "d", body: "b", scope: :global})

      # Simulate heavy use with poor outcomes for `bad`
      Skills.update(bad.id, fn s ->
        Map.merge(s, %{applied_count: 30, success_count: 2, failure_count: 28})
      end)

      # Good utility
      Skills.update(good.id, fn s ->
        Map.merge(s, %{applied_count: 30, success_count: 25, failure_count: 5})
      end)

      # Not yet enough applies to evaluate
      Skills.update(young.id, fn s ->
        Map.merge(s, %{applied_count: 2, success_count: 0, failure_count: 2})
      end)

      summary = Hygiene.compact()

      assert summary.demoted == 1
      assert Skills.get(bad.id).status == :archived
      assert Skills.get(good.id).status == :active
      assert Skills.get(young.id).status == :active
    end
  end

  describe "dedupe" do
    test "archives the newer of two near-identical skills" do
      # Give two skills identical embeddings so cosine = 1.0
      {:ok, older} = Skills.create(%{name: "older", description: "d", body: "b", scope: :global})
      Process.sleep(1_100)
      {:ok, newer} = Skills.create(%{name: "newer", description: "d", body: "b", scope: :global})

      Skills.update(older.id, fn s -> Map.put(s, :embedding, [1.0, 0.0, 0.0]) end)
      Skills.update(newer.id, fn s -> Map.put(s, :embedding, [1.0, 0.0, 0.0]) end)

      summary = Hygiene.compact()

      assert summary.deduped >= 1
      assert Skills.get(older.id).status == :active
      assert Skills.get(newer.id).status == :archived
    end

    test "does not flag distinct skills" do
      {:ok, a} = Skills.create(%{name: "a", description: "d", body: "b", scope: :global})
      {:ok, b} = Skills.create(%{name: "b", description: "d", body: "b", scope: :global})

      Skills.update(a.id, fn s -> Map.put(s, :embedding, [1.0, 0.0]) end)
      Skills.update(b.id, fn s -> Map.put(s, :embedding, [0.0, 1.0]) end)

      summary = Hygiene.compact()

      assert summary.deduped == 0
      assert Skills.get(a.id).status == :active
      assert Skills.get(b.id).status == :active
    end
  end

  describe "enforce_cap" do
    test "archives lowest-utility skills when over per-sector cap" do
      Application.put_env(:gitf, :skill_hygiene_per_sector_cap, 3)

      on_exit(fn -> Application.delete_env(:gitf, :skill_hygiene_per_sector_cap) end)

      # Create 5 global skills with varying utility
      skills =
        for i <- 1..5 do
          {:ok, s} =
            Skills.create(%{name: "cap-#{i}", description: "d", body: "b", scope: :global})

          # Ages and utilities: higher i = more applies and better success
          Skills.update(s.id, fn s ->
            Map.merge(s, %{applied_count: i * 10, success_count: i * 9, failure_count: i})
          end)

          s
        end

      summary = Hygiene.compact()

      assert summary.capped == 2

      # The bottom 2 (cap-1, cap-2) should be archived
      statuses = for s <- skills, do: Skills.get(s.id).status

      assert Enum.count(statuses, &(&1 == :archived)) == 2
      assert Skills.get(Enum.at(skills, 0).id).status == :archived
      assert Skills.get(Enum.at(skills, 4).id).status == :active
    end
  end
end
