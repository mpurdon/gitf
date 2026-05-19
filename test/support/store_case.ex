defmodule GiTF.StoreCase do
  @moduledoc """
  ExUnit.CaseTemplate that provides an isolated Archive store per test module.

  Usage:

      defmodule MyTest do
        use GiTF.StoreCase

        test "something", %{store_dir: store_dir} do
          # Archive is running with a fresh temp directory
        end
      end

  This replaces the pattern of manually calling `StoreHelper.stop_store()`
  + `Archive.start_link()` in every test's `setup` block. The template
  handles the lifecycle atomically:

  1. Ensures infrastructure (PubSub, Registry) is running
  2. Stops any existing Archive
  3. Creates a temp directory
  4. Starts a fresh Archive pointing at the temp dir
  5. On exit: stops the test Archive, cleans up the temp dir, and restores a
     fresh app-level Archive for whatever non-isolated test runs next

  All tests using this template run with `async: false` to avoid
  concurrent access to the singleton Archive process.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
    end
  end

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)

    GiTF.Test.StoreHelper.stop_store()
    {:ok, _pid} = GiTF.Archive.start_link(data_dir: store_dir)

    on_exit(fn ->
      GiTF.Test.StoreHelper.stop_store()

      # `File.rm_rf!` would raise (and fail the test report) when a
      # background process writes into the tmp dir between scan and
      # delete — common because the Archive's snapshot writer can
      # still flush after `stop_store/0`'s 10ms grace. Use the
      # non-bang variant, then retry a couple of times for any
      # late-write stragglers. If cleanup ultimately fails, leave a
      # trail in the test log but don't poison an otherwise-passing
      # test's result.
      cleanup_tmp_dir(store_dir, 3)

      # Leave a healthy app-level Archive behind so non-isolated tests that
      # run after this module (simulator / skills / E2E) don't inherit a
      # stopped or half-deleted store.
      GiTF.Test.StoreHelper.restore_app_store()
    end)

    %{store_dir: store_dir}
  end

  defp cleanup_tmp_dir(_dir, 0), do: :ok

  defp cleanup_tmp_dir(dir, attempts_left) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _posix, _path} ->
        # Wait for the late-write to land, then try again.
        Process.sleep(25)
        cleanup_tmp_dir(dir, attempts_left - 1)
    end
  end
end
