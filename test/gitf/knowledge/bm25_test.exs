defmodule GiTF.Knowledge.BM25Test do
  use ExUnit.Case, async: true

  alias GiTF.Knowledge.BM25

  defp doc(id, text), do: %{id: id, text: text}

  describe "rank/3" do
    test "ranks the doc containing the query term first" do
      docs = [
        doc(:a, "supervision trees and genservers"),
        doc(:b, "circuit breaker retry backoff"),
        doc(:c, "database migrations and ecto")
      ]

      ranked = BM25.rank("circuit breaker", docs, & &1.text)

      assert [{_score, %{id: :b}} | _] = ranked
    end

    test "rewards exact acronym / token matches (the semantic gap)" do
      docs = [
        doc(:a, "OTP application supervision"),
        doc(:b, "generic server behaviour")
      ]

      ranked = BM25.rank("OTP", docs, & &1.text)
      assert [{score, %{id: :a}}] = ranked
      assert score > 0.0
    end

    test "drops zero-score docs" do
      docs = [doc(:a, "alpha beta"), doc(:b, "gamma delta")]
      ranked = BM25.rank("beta", docs, & &1.text)
      assert length(ranked) == 1
      assert [{_s, %{id: :a}}] = ranked
    end

    test "empty query or empty corpus yields no results" do
      assert BM25.rank("", [doc(:a, "x y")], & &1.text) == []
      assert BM25.rank("query", [], & &1.text) == []
    end

    test "tokenize lowercases, splits, and drops single chars" do
      assert BM25.tokenize("Hello, World! a b12") == ["hello", "world", "b12"]
    end
  end
end
