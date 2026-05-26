defmodule GiTF.LSP.CollectTest do
  @moduledoc """
  Unit tests for `GiTF.LSP.collect_diagnostics/2` and
  `GiTF.LSP.collect_errors/2` — the facade helpers wired into the
  validation cross-check and the impl-phase self-check.

  Doesn't need a real LSP server: we exercise the error paths
  (`{:error, :disabled}`, `{:error, :sector_not_found}`) which are
  what the gated callers care about most.
  """
  use ExUnit.Case, async: false

  alias GiTF.LSP

  setup do
    prior_enabled = Application.get_env(:gitf, :lsp_enabled)
    prior_exe = Application.get_env(:gitf, :lsp_executable)

    Application.put_env(:gitf, :lsp_enabled, false)
    Application.put_env(:gitf, :lsp_executable, nil)

    on_exit(fn ->
      Application.put_env(:gitf, :lsp_enabled, prior_enabled || false)
      Application.put_env(:gitf, :lsp_executable, prior_exe)
    end)

    :ok
  end

  describe "collect_diagnostics/2 — error paths" do
    test "returns {:error, :sector_not_found} for unknown sector" do
      assert {:error, :sector_not_found} =
               LSP.collect_diagnostics("sec-does-not-exist", ["lib/foo.ex"])
    end

    test "empty file list short-circuits to ok-with-empty" do
      # Insert a sector record so the sector lookup succeeds; then an
      # empty file list should yield an empty result list without
      # actually invoking the LSP client.
      {:ok, sector} =
        GiTF.Archive.insert(:sectors, %{
          name: "lsp-collect-empty",
          path: System.tmp_dir!()
        })

      on_exit(fn -> GiTF.Archive.delete(:sectors, sector.id) end)

      assert {:ok, []} = LSP.collect_diagnostics(sector.id, [])
    end
  end

  describe "collect_errors/2" do
    test "filters non-error severities out of collect_diagnostics output" do
      # Stub `LSP.diagnostics/2` indirectly: a known-bad sector returns
      # {:error, _} which collect_diagnostics maps to {file, []}. So
      # we exercise the filter on the empty-result path: pairs with []
      # are dropped by collect_errors.
      {:ok, sector} =
        GiTF.Archive.insert(:sectors, %{
          name: "lsp-collect-errors-empty",
          path: System.tmp_dir!()
        })

      on_exit(fn -> GiTF.Archive.delete(:sectors, sector.id) end)

      # With LSP disabled, every file resolves to `{file, []}`, which
      # collect_errors then drops because there are no error
      # diagnostics. End state: empty list, no error.
      assert {:ok, []} = LSP.collect_errors(sector.id, ["lib/foo.ex", "lib/bar.ex"])
    end

    test "propagates {:error, :sector_not_found}" do
      assert {:error, :sector_not_found} =
               LSP.collect_errors("sec-missing", ["lib/foo.ex"])
    end
  end
end
