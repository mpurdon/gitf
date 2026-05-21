defmodule GiTF.LSP.EditsTest do
  use ExUnit.Case, async: true

  alias GiTF.LSP.Edits

  @tmp_dir System.tmp_dir!()

  setup do
    path =
      Path.join(@tmp_dir, "edits_test_#{:erlang.unique_integer([:positive])}.ex")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  describe "apply_workspace_edit/1" do
    test "applies a single in-line insertion", %{path: path} do
      File.write!(path, "alias Foo.Bar\n\ndefmodule M do\nend\n")

      edit = %{
        "changes" => %{
          "file://#{path}" => [
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 13},
                "end" => %{"line" => 0, "character" => 13}
              },
              "newText" => ", Baz"
            }
          ]
        }
      }

      assert {:ok, [^path]} = Edits.apply_workspace_edit(edit)
      assert File.read!(path) == "alias Foo.Bar, Baz\n\ndefmodule M do\nend\n"
    end

    test "replaces a multi-line range", %{path: path} do
      File.write!(path, "line0\nline1\nline2\nline3\n")

      edit = %{
        "changes" => %{
          "file://#{path}" => [
            %{
              "range" => %{
                "start" => %{"line" => 1, "character" => 0},
                "end" => %{"line" => 3, "character" => 0}
              },
              "newText" => "REPLACED\n"
            }
          ]
        }
      }

      assert {:ok, _} = Edits.apply_workspace_edit(edit)
      assert File.read!(path) == "line0\nREPLACED\nline3\n"
    end

    test "applies multiple edits per file in correct order", %{path: path} do
      File.write!(path, "AAAA\nBBBB\nCCCC\n")

      edit = %{
        "changes" => %{
          "file://#{path}" => [
            # Two edits; latest position first must not need re-ordering by caller
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 4}
              },
              "newText" => "1111"
            },
            %{
              "range" => %{
                "start" => %{"line" => 2, "character" => 0},
                "end" => %{"line" => 2, "character" => 4}
              },
              "newText" => "3333"
            }
          ]
        }
      }

      assert {:ok, _} = Edits.apply_workspace_edit(edit)
      assert File.read!(path) == "1111\nBBBB\n3333\n"
    end

    test "fails cleanly on unsupported URI scheme" do
      edit = %{
        "changes" => %{
          "untitled:/scratch.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 0}
              },
              "newText" => "x"
            }
          ]
        }
      }

      assert {:error, {_, {:unsupported_uri_scheme, _}}} = Edits.apply_workspace_edit(edit)
    end

    test "atomized keys also work (struct from server library)", %{path: path} do
      File.write!(path, "hi\n")

      edit = %{
        changes: %{
          "file://#{path}" => [
            %{
              range: %{
                start: %{line: 0, character: 2},
                end: %{line: 0, character: 2}
              },
              newText: "!"
            }
          ]
        }
      }

      assert {:ok, _} = Edits.apply_workspace_edit(edit)
      assert File.read!(path) == "hi!\n"
    end

    test "no-op edit list is a no-op", %{path: path} do
      File.write!(path, "unchanged\n")

      assert {:ok, _} = Edits.apply_workspace_edit(%{"changes" => %{}})
      assert File.read!(path) == "unchanged\n"
    end
  end
end
