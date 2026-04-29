defmodule Mix.Tasks.Gitf.Eval do
  @moduledoc """
  Runs the Factory's golden eval suite.

  ## Usage

      mix gitf.eval                          # all scenarios, console only
      mix gitf.eval --scenario skills_retrieval
      mix gitf.eval --json /tmp/eval.json    # also write JSON report
      mix gitf.eval --model sonnet           # forwarded to scenarios

  Exit code is non-zero when any case failed (skips do not fail the
  run). Wired into a nightly cron-routine, this catches model-upgrade
  regressions in retrieval / validator / refiner quality before they
  silently degrade the self-improving skill library.
  """
  @shortdoc "Run the gitf golden eval suite"

  use Mix.Task

  @switches [scenario: :string, json: :string, model: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    Mix.Task.run("app.start")

    eval_opts =
      [scenario: opts[:scenario], opts: scenario_opts(opts)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    report = GiTF.Eval.run(eval_opts)

    Mix.shell().info(GiTF.Eval.format_console(report))

    case opts[:json] do
      nil -> :ok
      path -> write_json(path, report)
    end

    if report.summary.fail > 0, do: System.halt(1)
  end

  defp scenario_opts(opts) do
    [model: opts[:model]]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp write_json(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true))
    Mix.shell().info("Wrote JSON report to #{path}")
  end
end
