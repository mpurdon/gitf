defmodule GiTF.DriftDesignClaimTest do
  @moduledoc """
  Drift used to score against the running op's `target_files` alone. A PR
  merged into main that landed in files the DESIGN claimed — but that no op
  had opened yet — read as plain `:behind`, auto-rebased, and let the
  mission finish against an assumption that no longer held. These pin the
  wider claim.
  """
  use ExUnit.Case, async: true

  alias GiTF.Phases.Design

  describe "Design.files/1" do
    test "collects every component's files, deduped and sorted" do
      design = %{
        "components" => [
          %{"name" => "a", "files" => ["src/b.ts", "src/a.rs"]},
          %{"name" => "b", "files" => ["src/a.rs"]}
        ]
      }

      assert Design.files(design) == ["src/a.rs", "src/b.ts"]
    end

    test "tolerates components with no files, and non-string entries" do
      design = %{
        "components" => [
          %{"name" => "no files"},
          %{"name" => "junk", "files" => [nil, 42, "src/ok.rs"]}
        ]
      }

      assert Design.files(design) == ["src/ok.rs"]
    end

    test "a missing or malformed design claims nothing" do
      assert Design.files(nil) == []
      assert Design.files(%{}) == []
      assert Design.files("not a design") == []
    end
  end

  describe "claimed_files/1" do
    test "a mission with no design artifact claims nothing" do
      GiTF.Test.StoreHelper.ensure_infrastructure()
      {:ok, m} = GiTF.Missions.create(%{goal: "no design yet"})

      assert Design.claimed_files(m.id) == []
    end

    test "reads the promoted design, which is what planning executed against" do
      GiTF.Test.StoreHelper.ensure_infrastructure()
      {:ok, m} = GiTF.Missions.create(%{goal: "has a design"})

      GiTF.Missions.store_artifact(m.id, "design", %{
        "components" => [%{"files" => ["src/windows/MainApp.tsx", "src-tauri/src/models.rs"]}]
      })

      assert Design.claimed_files(m.id) == [
               "src-tauri/src/models.rs",
               "src/windows/MainApp.tsx"
             ]
    end

    test "nil mission id is not an error" do
      assert Design.claimed_files(nil) == []
    end
  end
end
