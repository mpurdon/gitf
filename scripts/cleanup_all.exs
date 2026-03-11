path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read(path) |> elem(1) |> :erlang.binary_to_term()

ghosts = data[:ghosts] || %{}
ops = data[:ops] || %{}

ghosts = Map.new(ghosts, fn {id, b} ->
  if b.status in ["working", "provisioning"] do
    IO.puts("ghost #{id}: #{b.status} -> crashed")
    {id, %{b | status: "crashed"}}
  else
    {id, b}
  end
end)

ops = Map.new(ops, fn {id, j} ->
  if j.status in ["running", "assigned"] do
    IO.puts("op #{id}: #{j.status} -> pending")
    {id, %{j | status: "pending", ghost_id: nil}}
  else
    {id, j}
  end
end)

data = %{data | ghosts: ghosts, ops: ops}
File.write(path, :erlang.term_to_binary(data))
IO.puts("Done.")
