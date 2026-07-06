defmodule GiTF.Verification.Driver.Shell do
  @moduledoc """
  Shell driver for CLI / library / TUI / script modalities.

  Runs a scenario's `setup` then `steps` as shell commands in the target
  working directory, sandboxed via `GiTF.Sandbox.wrap_shell/2`, and captures a
  combined transcript (command, exit code, output) for the judge. A non-zero
  exit on any step marks the transcript `ok: false`, but the judge still reads
  the full output — "the command failed" can itself be the expected behaviour.
  """

  @behaviour GiTF.Verification.Driver

  @step_timeout_ms 120_000

  @impl true
  def run(scenario, context) do
    cwd = Map.fetch!(context, :cwd)
    risk = Map.get(context, :risk_level, :low)

    setup = Map.get(scenario, :setup, [])
    steps = Map.get(scenario, :steps, [])

    input = Map.get(scenario, :input)
    steps = if input, do: steps ++ [input], else: steps

    {lines, all_ok?} =
      Enum.reduce(setup ++ steps, {[], true}, fn cmd, {acc, ok?} ->
        {out, code} = run_cmd(cmd, cwd, risk)

        line =
          "$ #{cmd}\n(exit #{code})\n#{String.slice(out, 0, 4_000)}"

        {[line | acc], ok? and code == 0}
      end)

    %{
      ok: all_ok?,
      text: lines |> Enum.reverse() |> Enum.join("\n\n"),
      exit_code: if(all_ok?, do: 0, else: 1)
    }
  end

  defp run_cmd(command, cwd, risk) do
    {cmd, args} = GiTF.Sandbox.wrap_shell(command, cd: cwd, risk_level: risk)

    task =
      Task.async(fn ->
        System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, @step_timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, {out, code}} -> {out, code}
      _ -> {"(timed out after #{@step_timeout_ms}ms)", 124}
    end
  rescue
    e -> {"(driver error: #{Exception.message(e)})", 1}
  end
end
