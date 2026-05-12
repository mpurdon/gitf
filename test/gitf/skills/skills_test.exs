defmodule GiTF.SkillsTest do
  use GiTF.StoreCase

  alias GiTF.Skills

  setup do
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    :ok
  end

  describe "create/1" do
    test "creates a global skill with defaults" do
      assert {:ok, skill} =
               Skills.create(%{
                 name: "test-skill",
                 description: "a test",
                 body: "---\nname: test-skill\ndescription: a test\n---\nbody",
                 scope: :global
               })

      assert skill.id =~ ~r/^skill-/
      assert skill.scope == :global
      assert skill.sector_id == nil
      assert skill.source == :human
      assert skill.status == :active
      assert skill.applied_count == 0
      assert skill.success_count == 0
      assert skill.failure_count == 0
    end

    test "creates a sector-scoped skill" do
      assert {:ok, skill} =
               Skills.create(%{
                 name: "sector-skill",
                 description: "scoped",
                 body: "body",
                 scope: :sector,
                 sector_id: "sec-abc123"
               })

      assert skill.scope == :sector
      assert skill.sector_id == "sec-abc123"
    end

    test "rejects sector scope without sector_id" do
      assert {:error, {:missing_fields, [:sector_id]}} =
               Skills.create(%{
                 name: "bad",
                 description: "no sector",
                 body: "b",
                 scope: :sector
               })
    end

    test "rejects missing required fields" do
      assert {:error, {:missing_fields, missing}} = Skills.create(%{name: "x"})
      assert :description in missing
      assert :body in missing
      assert :scope in missing
    end

    test "rejects invalid scope" do
      assert {:error, {:invalid_scope, :wat}} =
               Skills.create(%{
                 name: "x",
                 description: "x",
                 body: "x",
                 scope: :wat
               })
    end
  end

  describe "list_global / list_for_sector / candidates_for" do
    setup do
      {:ok, g1} = Skills.create(%{name: "g1", description: "d", body: "b", scope: :global})
      {:ok, g2} = Skills.create(%{name: "g2", description: "d", body: "b", scope: :global})

      {:ok, s1} =
        Skills.create(%{
          name: "s1",
          description: "d",
          body: "b",
          scope: :sector,
          sector_id: "sec-A"
        })

      {:ok, s2} =
        Skills.create(%{
          name: "s2",
          description: "d",
          body: "b",
          scope: :sector,
          sector_id: "sec-B"
        })

      %{g1: g1, g2: g2, s1: s1, s2: s2}
    end

    test "list_global/0 returns only global skills", %{g1: g1, g2: g2} do
      ids = Skills.list_global() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([g1.id, g2.id])
    end

    test "list_for_sector/1 returns only that sector's skills", %{s1: s1} do
      ids = Skills.list_for_sector("sec-A") |> Enum.map(& &1.id)
      assert ids == [s1.id]
    end

    test "candidates_for/1 returns globals + sector skills", %{g1: g1, g2: g2, s1: s1} do
      ids = Skills.candidates_for("sec-A") |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([g1.id, g2.id, s1.id])
    end

    test "candidates_for/1 with nil sector returns globals only", %{g1: g1, g2: g2} do
      ids = Skills.candidates_for(nil) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([g1.id, g2.id])
    end

    test "archived skills are excluded from list functions" do
      {:ok, archived} =
        Skills.create(%{name: "archived", description: "d", body: "b", scope: :global})

      {:ok, _} = Skills.update(archived.id, fn s -> Map.put(s, :status, :archived) end)

      ids = Skills.list_global() |> Enum.map(& &1.id)
      refute archived.id in ids
    end
  end

  describe "bump/2" do
    test "increments counters atomically" do
      {:ok, s} = Skills.create(%{name: "n", description: "d", body: "b", scope: :global})

      {:ok, _} = Skills.bump(s.id, :applied_count)
      {:ok, _} = Skills.bump(s.id, :applied_count)
      {:ok, _} = Skills.bump(s.id, :success_count)
      {:ok, _} = Skills.bump(s.id, :failure_count)

      reloaded = Skills.get(s.id)
      assert reloaded.applied_count == 2
      assert reloaded.success_count == 1
      assert reloaded.failure_count == 1
    end
  end
end
