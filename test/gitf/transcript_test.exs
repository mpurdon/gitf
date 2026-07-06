defmodule GiTF.TranscriptTest do
  use ExUnit.Case, async: true

  alias GiTF.Transcript

  @tmp_dir System.tmp_dir!()

  describe "parse_file/1" do
    test "parses valid JSONL content" do
      path =
        write_transcript([
          %{"type" => "user", "message" => "hello"},
          %{
            "type" => "result",
            "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
            "model" => "claude-sonnet-4-20250514"
          }
        ])

      assert {:ok, entries} = Transcript.parse_file(path)
      assert length(entries) == 2
    end

    test "skips malformed lines" do
      path =
        write_raw_transcript("""
        {"type": "user", "message": "hello"}
        this is not json
        {"type": "result", "usage": {"input_tokens": 100}}
        """)

      assert {:ok, entries} = Transcript.parse_file(path)
      assert length(entries) == 2
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Transcript.parse_file("/nonexistent/path.jsonl")
    end

    test "handles empty file" do
      path = write_raw_transcript("")
      assert {:ok, []} = Transcript.parse_file(path)
    end
  end

  describe "extract_costs/1" do
    test "extracts cost entries from result-type entries" do
      entries = [
        %{"type" => "user", "message" => "hello"},
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 1000,
            "output_tokens" => 500,
            "cache_read_tokens" => 200,
            "cache_write_tokens" => 100
          },
          "model" => "claude-sonnet-4-20250514"
        },
        %{"type" => "assistant", "message" => "response"}
      ]

      costs = Transcript.extract_costs(entries)
      assert length(costs) == 1

      [cost] = costs
      assert cost.input_tokens == 1000
      assert cost.output_tokens == 500
      assert cost.cache_read_tokens == 200
      assert cost.cache_write_tokens == 100
      assert cost.model == "claude-sonnet-4-20250514"
    end

    test "counts cache tokens from the real Claude CLI usage keys" do
      # The Claude CLI stream-json emits the Anthropic API usage key names.
      # These must be counted (previously read as the never-present
      # cache_read_tokens/cache_write_tokens and silently dropped to $0).
      entries = [
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 1000,
            "output_tokens" => 500,
            "cache_read_input_tokens" => 8000,
            "cache_creation_input_tokens" => 1200
          },
          "model" => "claude-sonnet-4-20250514"
        }
      ]

      [cost] = Transcript.extract_costs(entries)
      assert cost.cache_read_tokens == 8000
      assert cost.cache_write_tokens == 1200
    end

    test "returns empty list when no result entries exist" do
      entries = [
        %{"type" => "user", "message" => "hello"},
        %{"type" => "assistant", "message" => "hi"}
      ]

      assert [] = Transcript.extract_costs(entries)
    end

    test "handles result entries without cache tokens" do
      entries = [
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 500,
            "output_tokens" => 200
          },
          "model" => "claude-opus-4-20250514"
        }
      ]

      [cost] = Transcript.extract_costs(entries)
      assert cost.input_tokens == 500
      assert cost.output_tokens == 200
      assert cost.cache_read_tokens == 0
      assert cost.cache_write_tokens == 0
      assert cost.model == "claude-opus-4-20250514"
    end

    test "extracts multiple cost entries" do
      entries = [
        %{
          "type" => "result",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
          "model" => "claude-sonnet-4-20250514"
        },
        %{"type" => "user", "message" => "more work"},
        %{
          "type" => "result",
          "usage" => %{"input_tokens" => 200, "output_tokens" => 100},
          "model" => "claude-sonnet-4-20250514"
        }
      ]

      costs = Transcript.extract_costs(entries)
      assert length(costs) == 2
    end
  end

  describe "parse_from_offset/2" do
    test "reads new content from offset" do
      path = write_raw_transcript("")
      line1 = Jason.encode!(%{"type" => "user", "message" => "hello"})
      File.write!(path, line1 <> "\n")

      {entries1, offset1} = Transcript.parse_from_offset(path, 0)
      assert length(entries1) == 1
      assert offset1 > 0

      # Append more content
      line2 =
        Jason.encode!(%{
          "type" => "result",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })

      File.write!(path, line1 <> "\n" <> line2 <> "\n")

      {entries2, offset2} = Transcript.parse_from_offset(path, offset1)
      assert length(entries2) == 1
      assert offset2 > offset1
    end

    test "returns empty list when no new content" do
      path = write_raw_transcript("line1\n")
      {_, offset} = Transcript.parse_from_offset(path, 0)

      {entries, same_offset} = Transcript.parse_from_offset(path, offset)
      assert entries == []
      assert same_offset == offset
    end

    test "handles missing file gracefully" do
      {entries, offset} = Transcript.parse_from_offset("/nonexistent.jsonl", 0)
      assert entries == []
      assert offset == 0
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp write_transcript(entries) do
    content =
      entries
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    write_raw_transcript(content)
  end

  defp write_raw_transcript(content) do
    name = "transcript_test_#{:erlang.unique_integer([:positive])}.jsonl"
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
