defmodule GiTF.LSP.Edits do
  @moduledoc """
  Applies an LSP `WorkspaceEdit` to the local filesystem.

  A `WorkspaceEdit` is `%{changes: %{uri => [TextEdit]}}` where each
  `TextEdit` is `%{range: %{start: %{line, character}, end: ...},
  newText: string}`. We apply edits in reverse-position order per
  file so earlier offsets stay valid as later ones rewrite the
  buffer.

  Bounds are 0-indexed lines + UTF-16 code units per the LSP spec.
  We approximate UTF-16 with byte offsets here since ElixirLS speaks
  UTF-8 and the spec allows servers to negotiate `positionEncoding`.
  If a server insists on UTF-16 and we hit a multi-byte issue, the
  fallback is to set `positionEncoding: "utf-8"` in initialize
  capabilities (a follow-up).

  Returns `{:ok, [path]}` on success listing the files actually
  changed, `{:error, reason}` if any edit failed (no partial writes —
  we read + splice all files first, then write).
  """

  @type apply_result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Applies the `changes` map of a `WorkspaceEdit`. `changes` may use
  string keys (`"changes"`, `"uri"`) as the server returned them or
  atomized keys; both are accepted.
  """
  @spec apply_workspace_edit(map()) :: apply_result()
  def apply_workspace_edit(edit) when is_map(edit) do
    changes = Map.get(edit, "changes") || Map.get(edit, :changes) || %{}

    with {:ok, file_changes} <- compute_changes(changes) do
      Enum.each(file_changes, fn {path, content} -> File.write!(path, content) end)
      {:ok, Enum.map(file_changes, fn {path, _} -> path end)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp compute_changes(changes) when is_map(changes) do
    Enum.reduce_while(changes, {:ok, []}, fn {uri, edits}, {:ok, acc} ->
      with {:ok, path} <- uri_to_path(uri),
           {:ok, body} <- File.read(path),
           {:ok, new_body} <- apply_text_edits(body, edits) do
        {:cont, {:ok, [{path, new_body} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {uri, reason}}}
      end
    end)
  end

  defp uri_to_path("file://" <> rest), do: {:ok, URI.decode(rest)}
  defp uri_to_path(other), do: {:error, {:unsupported_uri_scheme, other}}

  defp apply_text_edits(body, edits) when is_list(edits) do
    # Apply latest position first so earlier offsets stay valid.
    sorted =
      edits
      |> Enum.sort_by(&edit_anchor/1, :desc)

    Enum.reduce_while(sorted, {:ok, body}, fn edit, {:ok, b} ->
      case apply_one_edit(b, edit) do
        {:ok, b2} -> {:cont, {:ok, b2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp edit_anchor(edit) do
    range = Map.get(edit, "range") || Map.get(edit, :range) || %{}
    start = Map.get(range, "start") || Map.get(range, :start) || %{}
    {Map.get(start, "line") || Map.get(start, :line) || 0,
     Map.get(start, "character") || Map.get(start, :character) || 0}
  end

  defp apply_one_edit(body, edit) do
    new_text = Map.get(edit, "newText") || Map.get(edit, :newText) || ""
    range = Map.get(edit, "range") || Map.get(edit, :range) || %{}
    start = Map.get(range, "start") || Map.get(range, :start) || %{}
    finish = Map.get(range, "end") || Map.get(range, :end) || %{}

    sline = Map.get(start, "line") || Map.get(start, :line) || 0
    schar = Map.get(start, "character") || Map.get(start, :character) || 0
    eline = Map.get(finish, "line") || Map.get(finish, :line) || sline
    echar = Map.get(finish, "character") || Map.get(finish, :character) || schar

    with {:ok, start_offset} <- position_to_offset(body, sline, schar),
         {:ok, end_offset} <- position_to_offset(body, eline, echar),
         true <- end_offset >= start_offset do
      head = binary_part(body, 0, start_offset)
      tail = binary_part(body, end_offset, byte_size(body) - end_offset)
      {:ok, head <> new_text <> tail}
    else
      false -> {:error, :inverted_range}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # 0-indexed line + 0-indexed character (byte offset within the line)
  # → absolute byte offset in `body`.
  defp position_to_offset(body, line, character) when line >= 0 and character >= 0 do
    walk_to_line(body, line, 0)
    |> case do
      {:ok, line_start} ->
        offset = min(line_start + character, byte_size(body))
        {:ok, offset}

      err ->
        err
    end
  end

  defp position_to_offset(_, _, _), do: {:error, :negative_position}

  defp walk_to_line(_body, 0, offset), do: {:ok, offset}

  defp walk_to_line(body, remaining, offset) do
    case :binary.match(body, "\n", scope: {offset, byte_size(body) - offset}) do
      {match_offset, _len} ->
        walk_to_line(body, remaining - 1, match_offset + 1)

      :nomatch ->
        # Past end of file — clamp to EOF and let the splice trim.
        {:ok, byte_size(body)}
    end
  end
end
