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
  5. On exit: stops the Archive and cleans up the temp dir

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
      File.rm_rf!(store_dir)
    end)

    %{store_dir: store_dir}
  end
end
