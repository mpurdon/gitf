# Fix ghost-4bbddb status directly on disk
path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read!(path) |> :erlang.binary_to_term()

ghost = data[:ghosts]["ghost-4bbddb"]
IO.puts("Bee status before: #{ghost.status}")

ghost = %{ghost | status: "crashed"}
data = put_in(data, [:ghosts, "ghost-4bbddb"], ghost)

File.write!(path, :erlang.term_to_binary(data))
IO.puts("Bee status after: crashed")
