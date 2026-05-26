defmodule GiTF.ValidationLspTest do
  @moduledoc """
  Unit tests for `GiTF.Validation.validate_pass_against_diff/1`'s LSP
  cross-check (the part gated by `:lsp_validation_enabled`).

  Avoids spinning up ElixirLS by overriding `:lsp_executable` to a
  no-op shell script and routing `GiTF.LSP.diagnostics/2` calls
  through a stubbed client process. The validation logic only cares
  about the shape of the response (`{:ok, [diag]}` etc.); we don't
  need a real server.
  """
  use GiTF.StoreCase

  alias GiTF.Validation

  setup do
    prior_flag = Application.get_env(:gitf, :lsp_validation_enabled)
    prior_lsp = Application.get_env(:gitf, :lsp_enabled)
    prior_exe = Application.get_env(:gitf, :lsp_executable)

    on_exit(fn ->
      Application.put_env(:gitf, :lsp_validation_enabled, prior_flag || false)
      Application.put_env(:gitf, :lsp_enabled, prior_lsp || false)
      Application.put_env(:gitf, :lsp_executable, prior_exe)
    end)

    {:ok, sector} =
      GiTF.Archive.insert(:sectors, %{name: "lsp-val-test", path: System.tmp_dir!()})

    %{sector_id: sector.id}
  end

  defp mission_with_done_op(sector_id, changed_files) do
    %{
      id: "msn-#{:erlang.unique_integer([:positive])}",
      sector_id: sector_id,
      ops: [
        %{
          id: "op-1",
          status: "done",
          phase_job: false,
          changed_files: changed_files,
          files_changed: length(changed_files)
        }
      ]
    }
  end

  describe "validate_pass_against_diff/1 — flag off" do
    test "preserves pre-LSP behaviour: :ok when meaningful files exist",
         %{sector_id: sector_id} do
      Application.put_env(:gitf, :lsp_validation_enabled, false)

      mission = mission_with_done_op(sector_id, ["lib/foo.ex"])

      assert :ok = Validation.validate_pass_against_diff(mission)
    end

    test "still rejects when no impl ops are done", %{sector_id: sector_id} do
      Application.put_env(:gitf, :lsp_validation_enabled, false)

      mission = %{
        id: "msn-empty",
        sector_id: sector_id,
        ops: []
      }

      assert {:error, "no completed impl ops"} =
               Validation.validate_pass_against_diff(mission)
    end
  end

  describe "validate_pass_against_diff/1 — flag on, LSP unavailable" do
    test "falls back to pre-LSP :ok when LSP can't be reached",
         %{sector_id: sector_id} do
      Application.put_env(:gitf, :lsp_validation_enabled, true)
      # No :lsp_enabled / no driver → collect_errors returns {:error, :disabled}
      Application.put_env(:gitf, :lsp_enabled, false)

      mission = mission_with_done_op(sector_id, ["lib/foo.ex"])

      assert :ok = Validation.validate_pass_against_diff(mission)
    end
  end

  describe "changed_code_files/1" do
    test "returns deduped non-claude files from done impl ops",
         %{sector_id: sector_id} do
      mission =
        mission_with_done_op(sector_id, [
          "lib/foo.ex",
          "lib/foo.ex",
          ".claude/instructions.md",
          "lib/bar.ex"
        ])

      assert Validation.changed_code_files(mission) == ["lib/foo.ex", "lib/bar.ex"]
    end

    test "ignores phase_job ops and non-done ops", %{sector_id: sector_id} do
      mission = %{
        id: "msn-mix",
        sector_id: sector_id,
        ops: [
          %{id: "p1", status: "done", phase_job: true, changed_files: ["lib/triage.ex"]},
          %{id: "p2", status: "running", phase_job: false, changed_files: ["lib/in_flight.ex"]},
          %{id: "p3", status: "done", phase_job: false, changed_files: ["lib/done.ex"]}
        ]
      }

      assert Validation.changed_code_files(mission) == ["lib/done.ex"]
    end
  end
end
