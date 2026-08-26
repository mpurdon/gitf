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
        :ok
      else
        root =
          Path.join(System.tmp_dir!(), "gitf_visual_root_#{:erlang.unique_integer([:positive])}")

        File.mkdir_p!(root)
        Application.put_env(:gitf, :visual_screenshots_root, root)
        path = Path.join(root, "shot.png")

        try do
          case Capture.screenshot("https://example.com", path, timeout_ms: 60_000) do
            {:ok, ^path} ->
              assert File.exists?(path)
              assert File.stat!(path).size > 0

            {:error, {:exit, _, output}} = err when is_binary(output) ->
              # Playwright is on the PATH but a browser binary isn't.
              if String.contains?(output, "Executable doesn't exist") or
                   String.contains?(output, "playwright install") do
                :ok
              else
                flunk("unexpected screenshot error: #{inspect(err)}")
              end
          end
        after
          File.rm_rf!(root)
          Application.delete_env(:gitf, :visual_screenshots_root)
        end
      end
    end
  end
end
