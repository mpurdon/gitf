defmodule GiTF.Vault.FileTest do
  use ExUnit.Case, async: true

  alias GiTF.Vault.File, as: VFile

  setup do
    dir = Path.join(System.tmp_dir!(), "vault-file-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "write/2" do
    test "writes the body and returns its content hash", %{dir: dir} do
      path = Path.join(dir, "page.md")
      assert {:ok, hash} = VFile.write(path, "hello\n")
      assert File.read!(path) == "hello\n"
      assert hash == VFile.content_hash("hello\n")
    end

    test "creates parent directories", %{dir: dir} do
      path = Path.join([dir, "Sectors", "frontend", "Pages", "auth-flow.md"])
      assert {:ok, _} = VFile.write(path, "body")
      assert File.exists?(path)
    end

    test "overwrites existing file atomically", %{dir: dir} do
      path = Path.join(dir, "page.md")
      assert {:ok, _} = VFile.write(path, "v1")
      assert {:ok, _} = VFile.write(path, "v2")
      assert File.read!(path) == "v2"
    end

    test "leaves no temp files behind on success", %{dir: dir} do
      path = Path.join(dir, "page.md")
      assert {:ok, _} = VFile.write(path, "body")
      siblings = File.ls!(dir)
      assert siblings == ["page.md"]
    end
  end

  describe "read/1" do
    test "returns body and hash", %{dir: dir} do
      path = Path.join(dir, "page.md")
      File.write!(path, "content")

      assert {:ok, "content", hash} = VFile.read(path)
      assert hash == VFile.content_hash("content")
    end

    test "returns :enoent for missing files", %{dir: dir} do
      path = Path.join(dir, "missing.md")
      assert {:error, :enoent} = VFile.read(path)
    end
  end

  describe "content_hash/1" do
    test "is stable across calls" do
      assert VFile.content_hash("x") == VFile.content_hash("x")
    end

    test "differs for different bodies" do
      refute VFile.content_hash("a") == VFile.content_hash("b")
    end

    test "is hex-encoded SHA-256 (64 chars)" do
      assert String.length(VFile.content_hash("anything")) == 64
    end
  end

  describe "rm/1" do
    test "is idempotent on missing files", %{dir: dir} do
      assert :ok = VFile.rm(Path.join(dir, "absent.md"))
    end

    test "removes existing files", %{dir: dir} do
      path = Path.join(dir, "page.md")
      File.write!(path, "x")
      assert :ok = VFile.rm(path)
      refute File.exists?(path)
    end
  end
end
