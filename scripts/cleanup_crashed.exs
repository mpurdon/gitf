# Remove all crashed/stopped ghosts from the Archive
path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read!(path) |> :erlang.binary_to_term()

ghosts = data[:ghosts] || %{}
{keep, remove} = Map.split_with(ghosts, fn {_id, ghost} -> ghost.status == "working" end)

IO.puts("Keeping #{map_size(keep)} working ghosts")
IO.puts("Removing #{map_size(remove)} dead ghosts:")
for {id, ghost} <- remove, do: IO.puts("  #{id} [#{ghost.status}]")

data = %{data | ghosts: keep}
File.write!(path, :erlang.term_to_binary(data))
IO.puts("Done.")
