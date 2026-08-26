defmodule GiTF.LSP.FramingTest do
  use ExUnit.Case, async: true

  alias GiTF.LSP.Framing

  describe "encode/1" do
    test "wraps payload with Content-Length header + CRLF separators" do
      blob =
        Framing.encode(%{jsonrpc: "2.0", id: 1, method: "test", params: %{}})
        |> IO.iodata_to_binary()

      assert blob =~ ~r/^Content-Length: \d+\r\n\r\n/
      [_, body] = String.split(blob, "\r\n\r\n", parts: 2)
      assert {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "test"
      assert decoded["id"] == 1
    end

    test "Content-Length matches body byte size" do
      blob = Framing.encode(%{x: "héllo"}) |> IO.iodata_to_binary()
      ["Content-Length: " <> n_str | _] = String.split(blob, "\r\n", parts: 2)
      [_, body] = String.split(blob, "\r\n\r\n", parts: 2)
      assert byte_size(body) == String.to_integer(String.trim(n_str))
    end
  end

  describe "parse/1" do
    test "returns no messages on empty buffer" do
      assert {[], ""} = Framing.parse("")
    end

    test "returns no messages on partial header" do
      assert {[], "Content-Len"} = Framing.parse("Content-Len")
    end

    test "returns no messages when body is short" do
      buf = "Content-Length: 100\r\n\r\n{\"x\":1}"
      assert {[], ^buf} = Framing.parse(buf)
    end

    test "decodes a single complete message" do
      body = ~s({"jsonrpc":"2.0","id":1,"result":null})
      buf = "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"
      assert {[%{"id" => 1, "result" => nil}], ""} = Framing.parse(buf)
    end

    test "decodes multiple consecutive messages" do
      a = ~s({"id":1,"result":"a"})
      b = ~s({"id":2,"result":"b"})

      buf =
        "Content-Length: #{byte_size(a)}\r\n\r\n#{a}Content-Length: #{byte_size(b)}\r\n\r\n#{b}"

      {msgs, leftover} = Framing.parse(buf)
      assert length(msgs) == 2
      assert leftover == ""
      assert [%{"id" => 1}, %{"id" => 2}] = msgs
    end

    test "preserves leftover when last frame is incomplete" do
      a = ~s({"id":1})
      buf = "Content-Length: #{byte_size(a)}\r\n\r\n#{a}Content-Length: 999\r\n\r\nincomplet"
      {msgs, leftover} = Framing.parse(buf)
      assert length(msgs) == 1
      assert leftover =~ "Content-Length: 999"
    end
  end

  describe "round-trip" do
    test "encode then parse recovers the payload" do
      payload = %{jsonrpc: "2.0", id: 42, method: "x/y", params: %{a: [1, 2, 3]}}
      blob = Framing.encode(payload) |> IO.iodata_to_binary()
      assert {[decoded], ""} = Framing.parse(blob)
      assert decoded["id"] == 42
      assert decoded["method"] == "x/y"
      assert decoded["params"]["a"] == [1, 2, 3]
    end
  end
end
