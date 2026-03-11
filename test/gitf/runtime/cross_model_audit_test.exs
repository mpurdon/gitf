defmodule GiTF.Runtime.CrossModelAuditTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.CrossModelAudit

  describe "select_audit_model/1" do
    test "anthropic model gets google audit" do
      assert CrossModelAudit.select_audit_model("claude-sonnet-4-6") == "google:gemini-2.0-flash"
    end

    test "google model gets anthropic audit" do
      assert CrossModelAudit.select_audit_model("google:gemini-2.0-flash") == "anthropic:claude-haiku-4-5"
    end

    test "gemini model gets anthropic audit" do
      assert CrossModelAudit.select_audit_model("gemini-2.5-pro") == "anthropic:claude-haiku-4-5"
    end

    test "nil model defaults to google" do
      assert CrossModelAudit.select_audit_model(nil) == "google:gemini-2.0-flash"
    end

    test "unknown model defaults to google audit" do
      assert CrossModelAudit.select_audit_model("some-other-model") == "google:gemini-2.0-flash"
    end
  end
end

defmodule GiTF.Runtime.CrossModelAudit.EnabledTest do
  use ExUnit.Case, async: false

  alias GiTF.Runtime.CrossModelAudit

  setup do
    data_dir = Path.join(System.tmp_dir!(), "gitf_test_audit_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    GiTF.Test.StoreHelper.restart_store!(data_dir)

    on_exit(fn ->
      GiTF.Test.StoreHelper.stop_store()
      File.rm_rf!(data_dir)
    end)

    :ok
  end

  describe "enabled?/1" do
    test "returns false when sector not found" do
      refute CrossModelAudit.enabled?("nonexistent")
    end

    test "returns false when cross_model_audit not set" do
      GiTF.Archive.insert(:sectors, %{id: "cmb_test", path: "/tmp", name: "test"})
      refute CrossModelAudit.enabled?("cmb_test")
    end

    test "returns true when cross_model_audit is true" do
      GiTF.Archive.insert(:sectors, %{id: "cmb_audit", path: "/tmp", name: "audit", cross_model_audit: true})
      assert CrossModelAudit.enabled?("cmb_audit")
    end
  end
end
