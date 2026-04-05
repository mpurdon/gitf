defmodule CacheCompatibilityTest do
  use ExUnit.Case
  alias GiTF.Runtime.CacheControl

  test "only applies anthropic caching to anthropic models" do
    # Current implementation is naive and doesn't take model arg.
    # This test documents the CURRENT behavior (which is broken/naive)
    # or what we WANT (model-aware).

    # We WANT:
    # CacheControl.inject(msg, model)

    # If I try to call the current API:
    msg =
      CacheControl.mark_system_prompt(
        String.duplicate("test ", 1200),
        "anthropic:claude-3-5-sonnet"
      )

    assert Map.has_key?(msg, :cache_control)

    # This is "generic" but Gemini might reject it or ignore it.
    # We need to verify if we can make it model-specific.
  end
end
