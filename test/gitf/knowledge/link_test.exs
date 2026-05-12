defmodule GiTF.Knowledge.LinkTest do
  use ExUnit.Case, async: true

  alias GiTF.Knowledge.Link

  describe "parse_wikilinks/1" do
    test "extracts simple [[slug]] references" do
      assert Link.parse_wikilinks("see [[auth-flow]]") == ["auth-flow"]
    end

    test "extracts piped [[slug|alias]] references using the slug only" do
      assert Link.parse_wikilinks("[[auth-flow|the auth flow]]") == ["auth-flow"]
    end

    test "normalizes slugs the same way Vault.Path.slugify does" do
      assert Link.parse_wikilinks("[[Auth Flow]]") == ["auth-flow"]
      assert Link.parse_wikilinks("[[API Endpoints]] and [[api-endpoints]]") == ["api-endpoints"]
    end

    test "deduplicates while preserving first-appearance order" do
      body = "see [[a]], later [[b]], also [[a]] again"
      assert Link.parse_wikilinks(body) == ["a", "b"]
    end

    test "ignores [[...]] inside fenced code blocks" do
      body = """
      Real link: [[real]]

      ```elixir
      "[[not-a-link]]"
      ```

      Another real one: [[also-real]]
      """

      assert Link.parse_wikilinks(body) == ["real", "also-real"]
    end

    test "ignores [[...]] inside inline backticks" do
      body = "real [[real]] but `not [[a-link]]` here"
      assert Link.parse_wikilinks(body) == ["real"]
    end

    test "rejects empty link targets" do
      assert Link.parse_wikilinks("[[]] and [[ ]]") == []
    end

    test "supports multiple links per line" do
      assert Link.parse_wikilinks("[[a]] then [[b]] then [[c]]") == ["a", "b", "c"]
    end
  end
end
