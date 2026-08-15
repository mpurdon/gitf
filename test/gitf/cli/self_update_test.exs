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
  test "archive_version tolerates a spec without the trailing dot", %{tmp_dir: tmp_dir} do
    path = fake_escript(tmp_dir, ~s({application, gitf, [{vsn, "4.5.6"}]}))
    assert {:ok, "4.5.6"} = SelfUpdate.archive_version(path)
  end

  @tag :tmp_dir
  test "archive_version rejects a file that is not an escript", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "not-an-escript")
    File.write!(path, "just some text")
    assert {:error, _} = SelfUpdate.archive_version(path)
  end

  test "the installed escript, if present, is a readable archive" do
    installed = Path.expand("~/.local/bin/gitf")

    if File.exists?(installed) do
      assert {:ok, version} = SelfUpdate.archive_version(installed)
      assert version =~ ~r/^\d+\.\d+\.\d+$/
    end
  end
end
