defmodule GiTF.AuditLogTest do
  use ExUnit.Case, async: false

  alias GiTF.{Archive, AuditLog}

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    GiTF.Test.StoreHelper.stop_store()
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_audit_log_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  test "records carry actor, action, subject, details, and a timestamp" do
    assert :ok =
             AuditLog.record("mp@example.com", "approval.approve", "apr-123", %{notes: "lgtm"})

    assert [entry] = AuditLog.recent()
    assert entry.actor == "mp@example.com"
    assert entry.action == "approval.approve"
    assert entry.subject == "apr-123"
    assert entry.details == %{notes: "lgtm"}
    assert %DateTime{} = entry.at
    assert String.starts_with?(entry.id, "aud-")
  end

  test "recent/1 returns newest first and respects the limit" do
    for n <- 1..5 do
      :ok = AuditLog.record("mp@example.com", "settings.save", "config", %{n: n})
    end

    entries = AuditLog.recent(3)
    assert length(entries) == 3
    assert [%{details: %{n: 5}} | _] = entries
  end

  test "record/4 never raises even when the store is down" do
    GiTF.Test.StoreHelper.stop_store()
    assert :ok = AuditLog.record("mp@example.com", "approval.approve", "apr-x")
  end
end
