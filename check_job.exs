store_path = "/Users/mp/Projects/gitf-workspace/.gitf/store/gitf.etf"
data = File.read!(store_path) |> :erlang.binary_to_term()

op = get_in(data, [:ops, "op-0208de"])
if op do
  IO.puts("Job: #{op.id}")
  IO.puts("Title: #{op[:title]}")
  IO.puts("Status: #{op[:status]}")
  IO.puts("Phase: #{op[:phase]}")
  IO.puts("Phase op: #{op[:phase_job]}")
  IO.puts("Quest ID: #{op[:mission_id]}")
  IO.puts("Bee ID: #{op[:ghost_id]}")
  IO.puts("Error: #{inspect(op[:error])}")
  IO.puts("Failure reason: #{inspect(op[:failure_reason])}")
  IO.puts("\nFull op:")
  IO.inspect(op, pretty: true, limit: :infinity)
else
  IO.puts("Job not found")
end

ghost = get_in(data, [:ghosts, "ghost-c09b6f"])
if ghost do
  IO.puts("\n\nBee: #{ghost.id}")
  IO.puts("Status: #{ghost[:status]}")
  IO.puts("Error: #{inspect(ghost[:error])}")
  IO.puts("Exit reason: #{inspect(ghost[:exit_reason])}")
  IO.puts("\nFull ghost:")
  IO.inspect(ghost, pretty: true, limit: :infinity)
else
  IO.puts("\nBee not found")
end
