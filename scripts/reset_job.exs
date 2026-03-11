# Reset the stuck op directly on disk, bypassing Archive GenServer
path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read!(path) |> :erlang.binary_to_term()

op = data[:ops]["op-c54c34"]
IO.puts("Before: #{op.status}")

op = %{op | status: "pending", ghost_id: nil}
data = put_in(data, [:ops, "op-c54c34"], op)

binary = :erlang.term_to_binary(data)
File.write!(path, binary)

# Verify
data2 = File.read!(path) |> :erlang.binary_to_term()
IO.puts("After: #{data2[:ops]["op-c54c34"].status}")
