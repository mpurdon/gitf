defmodule GiTF.Vault.PathTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.Path, as: VPath

  describe "vault_root/1" do
    test "joins gitf root with the vault subdir" do
      assert VPath.vault_root("/tmp/gitf") == "/tmp/gitf/vault"
    end
  end

  describe "page_file/3" do
    test "puts sector pages under Sectors/<id>/Pages" do
      assert VPath.page_file("/r", "frontend", "auth-flow") ==
               "/r/vault/Sectors/frontend/Pages/auth-flow.md"
    end

    test "global pages live under _global/Pages" do
      assert VPath.page_file("/r", nil, "design-principles") ==
               "/r/vault/Sectors/_global/Pages/design-principles.md"
    end

    test "slugifies the segment to make filename-safe paths" do
      assert VPath.page_file("/r", "frontend", "Already Sluggy") ==
               "/r/vault/Sectors/frontend/Pages/Already Sluggy.md"
    end
  end

  describe "mission_file/4" do
    test "uses mission_id-slug filename" do
      assert VPath.mission_file("/r", "fe", "msn-abc", "Fix login flow") ==
               "/r/vault/Sectors/fe/Missions/msn-abc-fix-login-flow.md"
    end
  end

  describe "sector control files" do
    test "001_index.md sorts to the top" do
      assert VPath.sector_index_file("/r", "fe") == "/r/vault/Sectors/fe/001_index.md"
    end

    test "002_kanban.md sorts after the index" do
      assert VPath.sector_kanban_file("/r", "fe") == "/r/vault/Sectors/fe/002_kanban.md"
    end
  end

  describe "index_file/4" do
    test "pads the position to 3 digits" do
      assert VPath.index_file("/r", "fe", 1, "API Endpoints") ==
               "/r/vault/Sectors/fe/Indexes/001_API Endpoints.md"

      assert VPath.index_file("/r", "fe", 17, "Glossary") ==
               "/r/vault/Sectors/fe/Indexes/017_Glossary.md"
    end
  end

  describe "daily_note_file/2" do
    test "accepts a Date" do
      assert VPath.daily_note_file("/r", ~D[2026-05-04]) ==
               "/r/vault/Daily Notes/2026-05-04.md"
    end

    test "accepts an ISO string verbatim" do
      assert VPath.daily_note_file("/r", "2026-05-04") ==
               "/r/vault/Daily Notes/2026-05-04.md"
    end
  end

  describe "slugify/1" do
    test "lowercases and hyphenates" do
      assert VPath.slugify("Fix Login Flow on Safari iOS!") == "fix-login-flow-on-safari-ios"
    end

    test "collapses non-alphanumerics" do
      assert VPath.slugify("API/Auth — endpoints") == "api-auth-endpoints"
    end

    test "strips diacritics" do
      assert VPath.slugify("Café résumé") == "cafe-resume"
    end

    test "trims leading/trailing hyphens" do
      assert VPath.slugify("---hello---") == "hello"
    end

    test "empty input → empty slug" do
      assert VPath.slugify("") == ""
      assert VPath.slugify("  !!!  ") == ""
    end
  end

  describe "sanitize_segment/1" do
    test "strips path separators" do
      assert VPath.sanitize_segment("a/b\\c") == "a-b-c"
    end

    test "strips `..` and leading dots (no traversal, no hidden files)" do
      assert VPath.sanitize_segment(".hidden") == "hidden"
      # `..parent` collapses the `..` to `-` first.
      assert VPath.sanitize_segment("..parent") == "-parent"
    end

    test "never produces a traversal-shaped or empty segment" do
      # Adversarial inputs are rewritten, not silently allowed.
      for input <- ["", "...", "///", "..", "../"] do
        result = VPath.sanitize_segment(input)
        refute result == ""
        refute String.contains?(result, "..")
        refute String.contains?(result, "/")
      end
    end
  end
end
