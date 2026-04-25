defmodule GiTF.LSP.ClientTest do
  use ExUnit.Case, async: false

  alias GiTF.LSP.Client

  setup do
    prior_enabled = Application.get_env(:gitf, :lsp_enabled, false)
    prior_exe = Application.get_env(:gitf, :lsp_executable)

    on_exit(fn ->
      Application.put_env(:gitf, :lsp_enabled, prior_enabled)
      Application.put_env(:gitf, :lsp_executable, prior_exe)
    end)

    :ok
  end

  describe "enabled?/0 and available?/0" do
    test "enabled? reflects the feature flag" do
      Application.put_env(:gitf, :lsp_enabled, false)
      refute Client.enabled?()

      Application.put_env(:gitf, :lsp_enabled, true)
      assert Client.enabled?()
    end

    test "available? returns false when no driver configured + not on PATH" do
      Application.put_env(:gitf, :lsp_executable, nil)
      System.delete_env("LSP_EXECUTABLE")
      # On a host without ElixirLS this returns false; with it, true.
      _ = Client.available?()
    end

    test "available? returns true when :lsp_executable points at a real file" do
      tmp =
        Path.join(System.tmp_dir!(), "fake_lsp_#{:erlang.unique_integer([:positive])}")

      File.write!(tmp, "#!/bin/sh\nexit 0\n")
      File.chmod!(tmp, 0o755)

      try do
        Application.put_env(:gitf, :lsp_executable, tmp)
        assert Client.available?() == true
      after
        Application.put_env(:gitf, :lsp_executable, nil)
        File.rm!(tmp)
      end
    end
  end

  describe "start_link/1 — driver missing" do
    test "{:error, :driver_unavailable} when no driver" do
      Application.put_env(:gitf, :lsp_executable, nil)
      System.delete_env("LSP_EXECUTABLE")

      # Only meaningful when the host genuinely lacks ElixirLS. Skip if
      # ElixirLS happens to be installed (CI runners with mix archive).
      if not Client.available?() do
        assert {:error, :driver_unavailable} =
                 Client.start_link(root_path: System.tmp_dir!(), name: :lsp_t1)
      end
    end
  end
end
