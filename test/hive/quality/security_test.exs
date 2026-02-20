defmodule Hive.Quality.SecurityTest do
  use ExUnit.Case, async: true

  alias Hive.Quality.Security

  describe "scan/2" do
    test "returns security score and findings" do
      {:ok, result} = Security.scan("/tmp", :unknown)
      
      assert is_integer(result.score)
      assert result.score >= 0 and result.score <= 100
      assert is_list(result.findings)
      assert result.tool == "hive-security"
    end

    test "detects secrets in code" do
      # Create temp file with secret
      dir = System.tmp_dir!()
      file = Path.join(dir, "test_#{:rand.uniform(10000)}.ex")
      File.write!(file, """
      defmodule Test do
        @api_key "sk_live_EXAMPLE_KEY_12345"
      end
      """)
      
      {:ok, result} = Security.scan(dir, :elixir)
      
      # Should detect the API key pattern
      secret_findings = Enum.filter(result.findings, &(&1.type == "secret"))
      assert length(secret_findings) > 0
      
      File.rm(file)
    end

    test "handles missing audit tools gracefully" do
      {:ok, result} = Security.scan("/nonexistent", :elixir)
      
      # Should not crash, just return empty findings
      assert is_list(result.findings)
      assert result.score >= 0
    end
  end
end
