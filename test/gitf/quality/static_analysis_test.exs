defmodule GiTF.Quality.StaticAnalysisTest do
  use ExUnit.Case, async: true

  alias GiTF.Quality.StaticAnalysis

  describe "analyze/2" do
    test "returns empty results for unsupported language" do
      {:ok, result} = StaticAnalysis.analyze("/tmp", :unsupported)

      assert result.issues == []
      assert result.score == 100
    end

    test "handles missing tool gracefully" do
      {:ok, result} = StaticAnalysis.analyze("/nonexistent", :elixir)

      assert result.tool == "credo"
      assert result.score == 100
      # Tool may or may not be available, just check it doesn't crash
      assert is_boolean(Map.get(result, :available, true))
    end
  end
end
