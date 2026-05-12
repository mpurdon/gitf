defmodule GiTF.Vault.File do
  @moduledoc """
  Atomic file I/O for vault markdown files.

  Two guarantees this module provides:

    1. **Atomic writes**: never leaves a half-written file readable. Writes
       to a sibling temp file, fsyncs, then renames over the target. A
       reader either sees the previous content or the new content, never
       a partial write.
    2. **Content hashing**: SHA-256 over the byte-exact body. The Archive
       index uses this to detect operator edits made outside the Factory
       (e.g., directly in Obsidian) so we re-embed without overwriting.

  All paths are absolute. The caller is responsible for choosing them via
  `GiTF.Vault.Path`. Parent directories are created on demand with
  `File.mkdir_p/1`.
  """

  @type body :: binary()

  @doc """
  Atomically writes `body` to `path`. Creates parent directories.

  Returns `{:ok, content_hash}` on success.
  """
  @spec write(Path.t(), body()) :: {:ok, String.t()} | {:error, term()}
  def write(path, body) when is_binary(path) and is_binary(body) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, body) do
      {:ok, content_hash(body)}
    end
  end

  @doc """
  Reads `path`. Returns `{:ok, body, content_hash}` or `{:error, reason}`.
  Missing files return `{:error, :enoent}`.
  """
  @spec read(Path.t()) :: {:ok, body(), String.t()} | {:error, term()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body, content_hash(body)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Hex-encoded SHA-256 of the body bytes. Stable, fast, collision-resistant
  enough for change detection.

      iex> GiTF.Vault.File.content_hash("hello")
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  """
  @spec content_hash(body()) :: String.t()
  def content_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  @doc "Whether the file exists at `path`."
  @spec exists?(Path.t()) :: boolean()
  def exists?(path), do: File.exists?(path)

  @doc """
  Removes the file at `path`. No error if absent — vault deletes are
  idempotent (a previous crash mid-rename may have left no file).
  """
  @spec rm(Path.t()) :: :ok | {:error, term()}
  def rm(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  # -- Atomic write internals ------------------------------------------------

  # Write to a temp file in the same directory (rename across filesystems
  # is not atomic), fsync the temp file, then rename over the target.
  defp atomic_write(path, body) do
    tmp = path <> ".tmp." <> random_suffix()

    try do
      with :ok <- File.write(tmp, body, [:binary]),
           :ok <- fsync(tmp),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, _} = err ->
          File.rm(tmp)
          err
      end
    rescue
      e ->
        File.rm(tmp)
        {:error, {:exception, Exception.message(e)}}
    end
  end

  defp fsync(path) do
    case File.open(path, [:read, :raw]) do
      {:ok, fd} ->
        result =
          case :file.sync(fd) do
            :ok -> :ok
            other -> other
          end

        File.close(fd)
        result

      {:error, _} = err ->
        err
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
