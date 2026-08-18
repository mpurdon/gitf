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
  end
end
