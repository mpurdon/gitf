defmodule GiTF.LSP.SupervisorTest do
  use ExUnit.Case, async: false

  alias GiTF.LSP

  setup do
    prior_enabled = Application.get_env(:gitf, :lsp_enabled, false)
    prior_exe = Application.get_env(:gitf, :lsp_executable)
    Application.put_env(:gitf, :lsp_enabled, true)

    on_exit(fn ->
      Application.put_env(:gitf, :lsp_enabled, prior_enabled)
      Application.put_env(:gitf, :lsp_executable, prior_exe)
    end)

    :ok
  end

  describe "lookup_or_start/1 — guard rails" do
    test "{:error, :disabled} when feature flag is off" do
      Application.put_env(:gitf, :lsp_enabled, false)
      assert {:error, :disabled} = LSP.lookup_or_start("sec-anything")
    end

    test "{:error, :driver_unavailable} when no driver configured" do
      Application.put_env(:gitf, :lsp_executable, nil)
      System.delete_env("LSP_EXECUTABLE")

      if not GiTF.LSP.Client.available?() do
        assert {:error, :driver_unavailable} = LSP.lookup_or_start("sec-anything")
      end
    end

    test "{:error, :sector_not_found} when driver present but sector unknown" do
      tmp =
        Path.join(System.tmp_dir!(), "fake_lsp_#{:erlang.unique_integer([:positive])}")

      File.write!(tmp, "#!/bin/sh\nexit 0\n")
      File.chmod!(tmp, 0o755)

      try do
        Application.put_env(:gitf, :lsp_executable, tmp)

        Enum.each(GiTF.Archive.all(:sectors), fn s ->
          if s.id == "sec-no-such", do: GiTF.Archive.delete(:sectors, s.id)
        end)

        assert {:error, :sector_not_found} = LSP.lookup_or_start("sec-no-such")
      after
        Application.put_env(:gitf, :lsp_executable, nil)
        File.rm!(tmp)
      end
    end
  end

  describe "facade routing" do
    test "definition/4 short-circuits with :disabled when flag off" do
      Application.put_env(:gitf, :lsp_enabled, false)
      assert {:error, :disabled} = LSP.definition("sec-x", "/tmp/x.ex", 0, 0)
      assert {:error, :disabled} = LSP.references("sec-x", "/tmp/x.ex", 0, 0)
      assert {:error, :disabled} = LSP.hover("sec-x", "/tmp/x.ex", 0, 0)
    end
  end
end
