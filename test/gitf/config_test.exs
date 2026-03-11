defmodule GiTF.ConfigTest do
  use ExUnit.Case, async: true

  alias GiTF.Config

  @tmp_dir System.tmp_dir!()

  defp tmp_path(name) do
    Path.join(@tmp_dir, "gitf_config_test_#{:erlang.unique_integer([:positive])}_#{name}")
  end

  describe "default_config/0" do
    test "returns a map with section, queen, and costs sections" do
      config = Config.default_config()

      assert config["gitf"]["version"] == GiTF.version()
      assert config["major"]["max_ghosts"] == 5
      assert config["costs"]["warn_threshold_usd"] == 5.0
    end
  end

  describe "write_config/2 and read_config/1" do
    test "round-trips the default config through TOML" do
      path = tmp_path("config.toml")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Config.write_config(path)
      assert {:ok, parsed} = Config.read_config(path)

      assert parsed["gitf"]["version"] == GiTF.version()
      assert parsed["major"]["max_ghosts"] == 5
      assert parsed["costs"]["warn_threshold_usd"] == 5.0
    end

    test "writes custom config values" do
      path = tmp_path("custom.toml")
      on_exit(fn -> File.rm(path) end)

      custom = %{
        "gitf" => %{"version" => "99.0.0"},
        "major" => %{"max_ghosts" => 10}
      }

      assert :ok = Config.write_config(path, custom)
      assert {:ok, parsed} = Config.read_config(path)

      assert parsed["gitf"]["version"] == "99.0.0"
      assert parsed["major"]["max_ghosts"] == 10
    end

    test "round-trips nested maps and lists" do
      path = tmp_path("nested.toml")
      on_exit(fn -> File.rm(path) end)

      custom = %{
        "plugins" => %{"google" => %{"key" => "123", "models" => ["gemini"]}},
        "list" => %{"items" => [1, 2, 3]}
      }

      assert :ok = Config.write_config(path, custom)
      assert {:ok, parsed} = Config.read_config(path)

      assert parsed["plugins"]["google"]["key"] == "123"
      assert parsed["plugins"]["google"]["models"] == ["gemini"]
      assert parsed["list"]["items"] == [1, 2, 3]
    end
  end
end
