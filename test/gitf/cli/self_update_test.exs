defmodule GiTF.CLI.SelfUpdateTest do
  use ExUnit.Case, async: true

  alias GiTF.CLI.SelfUpdate

  defp fake_escript(tmp_dir, app_spec) do
    {:ok, {_, zip}} =
      :zip.create(~c"mem", [{~c"gitf/ebin/gitf.app", app_spec}], [:memory])

    path = Path.join(tmp_dir, "fake-gitf")
    File.write!(path, "#!/usr/bin/env escript\n%%! -escript main gitf_escript\n" <> zip)
    path
  end

  @tag :tmp_dir
  test "archive_version reads the vsn out of the embedded app spec", %{tmp_dir: tmp_dir} do
    path = fake_escript(tmp_dir, ~s({application, gitf, [{vsn, "1.2.3"}]}.))
    assert {:ok, "1.2.3"} = SelfUpdate.archive_version(path)
  end

  @tag :tmp_dir
  test "archive_version rejects a file that is not an escript", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "not-an-escript")
    File.write!(path, "just some text")
    assert {:error, _} = SelfUpdate.archive_version(path)
  end
end
