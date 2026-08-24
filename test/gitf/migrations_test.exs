defmodule GiTF.MigrationsTest do
  use GiTF.StoreCase

  alias GiTF.{Archive, Migrations}

  @cora_command "npm ci && test -f node_modules/typescript/lib/lib.es5.d.ts || " <>
                  "(rm -rf node_modules && npm cache verify && npm ci) ; npm run typecheck && " <>
                  "bash /var/lib/gitf/probes/cora-smoke.sh"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "gitf_migrations_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  # Archive.init already ran every migration, so rewind the stamp to force the
  # one under test to run against records we control.
  defp rewind_to(version) do
    Archive.put(:metadata, %{id: "schema_version", version: version})
  end

  describe "migration 9: validation_timeout_ms backfill" do
    test "derives a budget from the stored command when the path is gone", %{tmp: tmp} do
      {:ok, sector} =
        Archive.put(:sectors, %{
          id: "sec-cora",
          name: "cora",
          path: Path.join(tmp, "deleted"),
          validation_command: @cora_command
        })

      refute Map.has_key?(sector, :validation_timeout_ms)

      rewind_to(8)
      :ok = Migrations.migrate!()

      # No checkout to detect against, so the `npm ci` / `probes/` markers on
      # the stored command carry it alone: the 10m unknown bucket, doubled.
      assert Archive.get(:sectors, "sec-cora").validation_timeout_ms == 1_200_000
    end

    test "re-detects against the live checkout when the path still exists", %{tmp: tmp} do
      path = Path.join(tmp, "tauri-sector")
      File.mkdir_p!(Path.join(path, "src-tauri"))
      File.write!(Path.join(path, "package.json"), ~s({"dependencies": {"react": "^18.0.0"}}))

      {:ok, _} =
        Archive.put(:sectors, %{
          id: "sec-live",
          name: "live",
          path: path,
          validation_command: @cora_command
        })

      rewind_to(8)
      :ok = Migrations.migrate!()

      assert Archive.get(:sectors, "sec-live").validation_timeout_ms == 1_800_000
    end

    test "a sector with no validation command keeps the 2-minute default", %{tmp: tmp} do
      {:ok, _} =
        Archive.put(:sectors, %{
          id: "sec-bare",
          name: "bare",
          path: tmp,
          validation_command: nil
        })

      rewind_to(8)
      :ok = Migrations.migrate!()

      assert Archive.get(:sectors, "sec-bare").validation_timeout_ms == 120_000
    end

    test "does not overwrite an operator's existing override", %{tmp: tmp} do
      {:ok, _} =
        Archive.put(:sectors, %{
          id: "sec-set",
          name: "set",
          path: tmp,
          validation_command: @cora_command,
          validation_timeout_ms: 45_000
        })

      rewind_to(8)
      :ok = Migrations.migrate!()

      assert Archive.get(:sectors, "sec-set").validation_timeout_ms == 45_000
    end

    test "stamps the store at the current version" do
      rewind_to(8)
      :ok = Migrations.migrate!()

      assert Migrations.get_schema_version() == 9
    end
  end

  test "refuses to run a downgraded release against a newer store" do
    rewind_to(999)

    assert_raise RuntimeError, ~r/refusing to run a downgraded release/, fn ->
      Migrations.migrate!()
    end
  end
end
