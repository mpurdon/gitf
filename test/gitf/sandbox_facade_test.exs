defmodule GiTF.SandboxFacadeTest do
  use ExUnit.Case, async: false

  alias GiTF.Sandbox

  describe "enabled?/0" do
    test "defaults to true" do
      Application.delete_env(:gitf, :sandbox_enabled)
      assert Sandbox.enabled?()
    end

    test "false when explicitly disabled" do
      Application.put_env(:gitf, :sandbox_enabled, false)
      on_exit(fn -> Application.delete_env(:gitf, :sandbox_enabled) end)
      refute Sandbox.enabled?()
    end
  end

  describe "required?/0 and check_policy/0" do
    test "not required by default" do
      Application.delete_env(:gitf, :sandbox_required)
      refute Sandbox.required?()
      assert :ok = Sandbox.check_policy()
    end

    test "check_policy fails when required but sandboxing is disabled" do
      Application.put_env(:gitf, :sandbox_required, true)
      Application.put_env(:gitf, :sandbox_enabled, false)

      on_exit(fn ->
        Application.delete_env(:gitf, :sandbox_required)
        Application.delete_env(:gitf, :sandbox_enabled)
      end)

      assert {:error, :sandbox_required_but_unavailable} = Sandbox.check_policy()
    end

    test "check_policy fails when required and only the local adapter is available" do
      Application.put_env(:gitf, :sandbox_required, true)
      Application.put_env(:gitf, :sandbox_adapter, GiTF.Sandbox.Local)

      on_exit(fn ->
        Application.delete_env(:gitf, :sandbox_required)
        Application.delete_env(:gitf, :sandbox_adapter)
      end)

      assert {:error, :sandbox_required_but_unavailable} = Sandbox.check_policy()
    end

    test "wrap_shell raises under required policy with no effective sandbox" do
      Application.put_env(:gitf, :sandbox_required, true)
      Application.put_env(:gitf, :sandbox_enabled, false)

      on_exit(fn ->
        Application.delete_env(:gitf, :sandbox_required)
        Application.delete_env(:gitf, :sandbox_enabled)
      end)

      assert_raise GiTF.Sandbox.PolicyError, fn ->
        Sandbox.wrap_shell("mix test", cd: "/tmp")
      end
    end
  end

  describe "wrap_shell/2" do
    test "returns a plain sh invocation when sandboxing is disabled" do
      Application.put_env(:gitf, :sandbox_enabled, false)
      on_exit(fn -> Application.delete_env(:gitf, :sandbox_enabled) end)

      assert {"sh", ["-c", "mix test"]} = Sandbox.wrap_shell("mix test", cd: "/tmp")
    end

    test "wraps in the kernel sandbox when enabled and available" do
      Application.put_env(:gitf, :sandbox_enabled, true)
      on_exit(fn -> Application.delete_env(:gitf, :sandbox_enabled) end)

      {cmd, args} = Sandbox.wrap_shell("mix test", cd: "/tmp")

      if Sandbox.available?() and Sandbox.name() != "local" and
           System.find_executable(Sandbox.name()) do
        # The original command is still present inside the wrapped args.
        assert cmd != "sh"
        assert Enum.any?(args, &(&1 == "mix test"))
      else
        assert {^cmd, _} = {"sh", args}
      end
    end
  end
end
