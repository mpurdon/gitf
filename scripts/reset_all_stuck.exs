# Reset all stuck ghosts and ops directly on disk
path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read!(path) |> :erlang.binary_to_term()

# Fix all "working" ghosts -> crashed
ghosts = data[:ghosts] || %{}
fixed_bees = Map.new(ghosts, fn {id, ghost} ->
  if ghost.status == "working" do
    IO.puts("ghost #{id}: working -> crashed")
    {id, %{ghost | status: "crashed"}}
  else
    {id, ghost}
  end
end)

# Fix all "running" ops -> failed, then pending
ops = data[:ops] || %{}
fixed_jobs = Map.new(ops, fn {id, op} ->
  if op.status == "running" do
    IO.puts("op #{id}: running -> pending (was #{op.title})")
    {id, %{op | status: "pending", ghost_id: nil}}
  else
    {id, op}
  end
end)

data = %{data | ghosts: fixed_bees, ops: fixed_jobs}
File.write!(path, :erlang.term_to_binary(data))

IO.puts("\nDone. All stuck ghosts crashed, all running ops reset to pending.")
