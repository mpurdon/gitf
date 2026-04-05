defmodule CacheIntegrationTest do
  use ExUnit.Case

  alias GiTF.Runtime.CacheControl

  test "identifies large content for caching" do
    large_content = String.duplicate("a", 5000)
    assert CacheControl.should_cache?(large_content)

    small_content = "small"
    refute CacheControl.should_cache?(small_content)
  end
end
