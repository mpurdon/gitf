defmodule GiTF.Visual.CaptureTest do
  use ExUnit.Case, async: false

  alias GiTF.Visual.Capture

  setup do
    prior = Application.get_env(:gitf, :visual_capture_enabled, false)
    on_exit(fn -> Application.put_env(:gitf, :visual_capture_enabled, prior) end)
    :ok
  end

  describe "enabled?/0" do
    test "false by default" do
      Application.put_env(:gitf, :visual_capture_enabled, false)
      refute Capture.enabled?()
    end

    test "true when flag is set" do
      Application.put_env(:gitf, :visual_capture_enabled, true)
      assert Capture.enabled?()
    end
  end

  describe "screenshot/3 — guard rails" do
    test "{:error, :disabled} when feature flag is off" do
      Application.put_env(:gitf, :visual_capture_enabled, false)

      assert {:error, :disabled} =
               Capture.screenshot("https://example.com", "/tmp/x.png")
    end

    test "{:error, :driver_unavailable} when driver missing" do
      Application.put_env(:gitf, :visual_capture_enabled, true)

      # Force the cached driver state to false
      :persistent_term.put({Capture, :available}, false)

      try do
        assert {:error, :driver_unavailable} =
                 Capture.screenshot("https://example.com", "/tmp/x.png")
      after
        Capture.invalidate_driver_cache()
      end
    end
  end

  describe "available?/0 caching" do
    test "invalidate_driver_cache forces re-probe on next call" do
      :persistent_term.put({Capture, :available}, false)
      assert Capture.available?() == false
      Capture.invalidate_driver_cache()
      # After invalidate, the next call re-probes; we don't assert the
      # outcome because it depends on the host having `npx playwright`.
      _ = Capture.available?()
    end
  end

  describe "screenshot/3 — end-to-end (skipped unless browser available)" do
    @describetag :browser

    test "captures example.com to a tmp PNG" do
      Application.put_env(:gitf, :visual_capture_enabled, true)
      Capture.invalidate_driver_cache()

      if not Capture.available?() do
        # Mark as a no-op when Playwright isn't installed; this tag is
        # not configured for default runs.
        :ok
      else
        path = Path.join(System.tmp_dir!(), "gitf_visual_test_#{:erlang.unique_integer([:positive])}.png")

        try do
          assert {:ok, ^path} = Capture.screenshot("https://example.com", path, timeout_ms: 60_000)
          assert File.exists?(path)
          assert File.stat!(path).size > 0
        after
          File.rm(path)
        end
      end
    end
  end
end
