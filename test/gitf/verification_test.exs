defmodule GiTF.VerificationTest do
  use ExUnit.Case, async: false

  alias GiTF.Verification
  alias GiTF.Verification.Driver

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_verif_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "Driver.for_modality/1" do
    test "maps cli/library/tui to the shell driver" do
      assert {:ok, Driver.Shell} = Driver.for_modality("cli")
      assert {:ok, Driver.Shell} = Driver.for_modality(:library)
      assert {:ok, Driver.Shell} = Driver.for_modality("tui")
    end

    test "maps http/service to the http driver" do
      assert {:ok, Driver.Http} = Driver.for_modality("http")
      assert {:ok, Driver.Http} = Driver.for_modality("service")
    end

    test "unknown modality errors" do
      assert {:error, :unknown_modality} = Driver.for_modality("hologram")
    end
  end

  describe "Driver.Shell.run/2" do
    test "captures a passing command transcript", %{tmp: tmp} do
      scenario = %{name: "echo", expect: "prints hi", steps: ["echo hi"]}
      t = Driver.Shell.run(scenario, %{cwd: tmp})

      assert t.ok
      assert t.text =~ "hi"
      assert t.exit_code == 0
    end

    test "marks a failing command transcript not-ok but keeps output", %{tmp: tmp} do
      scenario = %{name: "fail", expect: "fails", steps: ["sh -c 'echo boom; exit 3'"]}
      t = Driver.Shell.run(scenario, %{cwd: tmp})

      refute t.ok
      assert t.text =~ "boom"
      assert t.text =~ "exit 3"
    end
  end

  describe "profile/1 + profile?/1" do
    test "no profile when sector lacks one", %{} do
      {:ok, sector} = GiTF.Archive.insert(:sectors, %{name: "plain"})
      refute Verification.profile?(sector.id)
      assert Verification.profile(sector.id) == nil
      assert Verification.run(sector.id, "/tmp") == :no_profile
    end

    test "normalizes a string-keyed profile", %{} do
      {:ok, sector} =
        GiTF.Archive.insert(:sectors, %{
          name: "cli-tool",
          verification_profile: %{
            "modality" => "cli",
            "scenarios" => [
              %{"name" => "help", "steps" => ["true"], "expect" => "shows help"}
            ]
          }
        })

      assert Verification.profile?(sector.id)
      p = Verification.profile(sector.id)
      assert p.modality == "cli"
      assert [%{name: "help", expect: "shows help", steps: ["true"]}] = p.scenarios
    end

    test "drops scenarios missing name or expect", %{} do
      {:ok, sector} =
        GiTF.Archive.insert(:sectors, %{
          name: "partial",
          verification_profile: %{
            "modality" => "cli",
            "scenarios" => [
              %{"name" => "ok", "expect" => "e", "steps" => []},
              %{"steps" => ["x"]}
            ]
          }
        })

      assert length(Verification.profile(sector.id).scenarios) == 1
    end
  end
end
