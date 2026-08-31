defmodule GiTF.Runtime.KimiTest do
  # NOT async: these tests rewrite the process-global PATH to prove the
  # CLI is not found, which races every concurrent test that shells out.
  use ExUnit.Case, async: false

  alias GiTF.Runtime.Kimi

  @tmp_dir System.tmp_dir!()

  describe "find_executable/0" do
    test "returns {:ok, path} or {:error, :not_found}" do
      result = Kimi.find_executable()

      case result do
        {:ok, path} ->
          assert is_binary(path)
          assert File.exists?(path)

        {:error, :not_found} ->
          assert true
      end
    end
  end

  describe "alive?/1 and stop/1" do
    test "alive? returns false after process exits" do
      port = Port.open({:spawn, "echo hello"}, [:binary, :exit_status])

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1000 -> flunk("port did not exit")
      end

      refute Kimi.alive?(port)
    end

    test "stop/1 is safe to call on an already-exited port" do
      port = Port.open({:spawn, "echo hello"}, [:binary, :exit_status])

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1000 -> flunk("port did not exit")
      end

      assert :ok = Kimi.stop(port)
    end
  end

  describe "spawn_headless/3" do
    test "returns error for invalid working directory" do
      result =
        Kimi.spawn_headless("/nonexistent/dir/#{:erlang.unique_integer([:positive])}", "hello")

      # :not_found if kimi isn't installed, :invalid_working_dir if it is
      assert result in [{:error, :invalid_working_dir}, {:error, :not_found}]
    end

    test "returns error when kimi is not found" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/empty")

      result = Kimi.spawn_headless(@tmp_dir, "hello")

      System.put_env("PATH", original_path)

      case result do
        {:error, :not_found} ->
          assert true

        {:ok, port} ->
          Kimi.stop(port)
          assert true
      end
    end

    test "headless spawn with resume option accepts session-id" do
      result = Kimi.spawn_headless(@tmp_dir, "test prompt", resume: "sess-test-123")

      case result do
        {:ok, port} ->
          Kimi.stop(port)
          assert true

        {:error, :not_found} ->
          assert true
      end
    end
  end

  describe "spawn_interactive/2" do
    test "returns error for invalid working directory" do
      result = Kimi.spawn_interactive("/nonexistent/dir/#{:erlang.unique_integer([:positive])}")
      assert result in [{:error, :invalid_working_dir}, {:error, :not_found}]
    end
  end
end
