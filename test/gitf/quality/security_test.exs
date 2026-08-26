defmodule GiTF.Quality.SecurityTest do
  use ExUnit.Case, async: true

  alias GiTF.Quality.Security

  describe "scan/2" do
    test "returns security score and findings" do
      {:ok, result} = Security.scan("/tmp", :unknown)

      assert is_integer(result.score)
      assert result.score >= 0 and result.score <= 100
      assert is_list(result.findings)
      assert result.tool == "section-security"
    end

    test "detects secrets in code" do
      # Create an isolated temp dir with a secret file
      dir = Path.join(System.tmp_dir!(), "gitf_sec_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file = Path.join(dir, "test_secret.ex")

      File.write!(file, """
      defmodule Test do
        api_key = "sk_live_EXAMPLE_KEY_12345"
        password = "super_secret_password_1234"
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, result} = Security.scan(dir, :elixir)

      # Should detect the API key pattern
      secret_findings = Enum.filter(result.findings, &(&1.type == "secret"))
      assert length(secret_findings) > 0
    end

    test "ignores vendored directories — the verdict must not depend on install state" do
      # msn-aa92dd: the same worktree scored pass before `npm ci` and 0 after,
      # because the scan's first 500 wildcard files became vendor JS.
      dir = Path.join(System.tmp_dir!(), "gitf_sec_vendor_#{:erlang.unique_integer([:positive])}")
      vendored = Path.join(dir, "node_modules/some-dep")
      File.mkdir_p!(vendored)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(vendored, "index.js"), """
      eval("boom");
      element.innerHTML = userInput;
      const api_key = "sk_live_TOTALLY_VENDORED_KEY_12345";
      """)

      File.write!(Path.join(dir, "app.js"), "const ok = 1;\n")

      {:ok, result} = Security.scan(dir, :javascript)

      vendor_findings =
        Enum.filter(result.findings, &String.starts_with?(&1.file, "node_modules"))

      assert vendor_findings == []
    end

    test "handles missing audit tools gracefully" do
      {:ok, result} = Security.scan("/nonexistent", :elixir)

      # Should not crash, just return empty findings
      assert is_list(result.findings)
      assert result.score >= 0
    end
  end
end
