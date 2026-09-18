defmodule GiTF.Ghost.FailureClassTest do
  use ExUnit.Case, async: true

  alias GiTF.Ghost.FailureClass

  describe "classify/1" do
    test "the real reason string from the 2026-08-18 Anthropic 5xx is a provider error" do
      # Verbatim shape of Worker.mark_failed's reason for a CLI exit: the
      # trust warning leads, but the API error inside makes it provider-side.
      reason =
        "Exit code 1: Ignoring 20 permissions.allow entries from .claude/settings.json: " <>
          "this workspace has not been trusted. ... API Error: Server error"

      assert FailureClass.classify(reason) == :provider_error
    end

    test "provider signatures: overloaded, rate limit, 503, stream error events" do
      for reason <- [
            "API error: overloaded_error",
            "Rate limit exceeded, retry after 60s",
            "503 Service Unavailable from upstream",
            ~s(Exit code 1: {"type":"error","error":{"type":"api_error"}})
          ] do
        assert FailureClass.classify(reason) == :provider_error, reason
      end
    end

    test "timeouts classify as :timeout" do
      assert FailureClass.classify("Generation timed out after 200000ms") == :timeout
      assert FailureClass.classify(:timeout) == :timeout
    end

    test "empty-success and admission-control failures get their own classes" do
      assert FailureClass.classify("Ghost reported success but produced 0 file changes") ==
               :no_changes

      assert FailureClass.classify(":blocked") == :blocked
      assert FailureClass.classify(:blocked) == :blocked
    end

    test "everything else is :unknown, never a crash" do
      assert FailureClass.classify("Exit code 1: cargo build failed") == :unknown
      assert FailureClass.classify({:unexpected, :tuple}) == :unknown
      assert FailureClass.classify(nil) == :unknown
    end

    test "the 2026-09-08 missing-binary box incident is :fatal, not :unknown" do
      # The replaced box came up with no `claude` on PATH. Every op on the
      # mission burned three retries and ~40 minutes of backoff against it.
      assert FailureClass.classify("sh: claude: command not found") == :fatal
      assert FailureClass.classify("Claude Code is not installed") == :fatal
      assert FailureClass.classify(:enoent) == :fatal
    end

    test "credential failures are :fatal even though the provider wraps them in an API error" do
      # This is why :fatal is tested first — every one of these also matches
      # a provider signature, and provider_error would retry them.
      for reason <- [
            ~s(API Error: {"type":"error","error":{"type":"authentication_error"}}),
            "API error: invalid x-api-key",
            "Request failed: not authenticated"
          ] do
        assert FailureClass.classify(reason) == :fatal, reason
      end
    end

    test "a mission ABOUT auth does not get its ops marked fatal" do
      # The reason string carries the ghost's own tool output, so bare
      # words like "unauthorized" are not safe fatal signatures.
      for reason <- [
            "Exit code 1: test failure — expected 401 Unauthorized, got 200",
            "Exit code 1: EACCES: permission denied, open 'dist/main.js'",
            "Exit code 1: ENOENT: no such file or directory, open 'src/missing.ts'"
          ] do
        refute FailureClass.classify(reason) == :fatal, reason
      end
    end
  end

  describe "retryable?/1 and provider_fault?/1" do
    test "only :fatal is unretryable" do
      refute FailureClass.retryable?(:fatal)

      for class <- [:provider_error, :timeout, :no_changes, :blocked, :unknown] do
        assert FailureClass.retryable?(class), inspect(class)
      end
    end

    test "only :provider_error spares the capability budget" do
      assert FailureClass.provider_fault?(:provider_error)

      for class <- [:fatal, :timeout, :no_changes, :blocked, :unknown] do
        refute FailureClass.provider_fault?(class), inspect(class)
      end
    end
  end
end
