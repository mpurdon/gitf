defmodule GiTF.Eval.Scenario do
  @moduledoc """
  Behaviour for golden-evaluation scenarios.

  A scenario is a named bundle of test cases that exercise one
  LLM-touching component of the Factory (Skills retrieval, validator,
  refiner, triage classifier, ...). Unlike ExUnit tests, scenarios are
  meant to be re-run periodically against live LLM/embedding endpoints
  to detect quality regressions when models or prompts change.

  Each scenario implements four callbacks:

    * `name/0` — short stable identifier (snake_case), used by
      `--scenario` flag and JSON reports.
    * `description/0` — one-line human description shown in console.
    * `cases/0` — list of case maps. The shape is scenario-defined; the
      runner just hands them to `run/2` one at a time.
    * `run/2` — execute one case, return `{:pass, meta}` /
      `{:fail, meta}` / `{:skip, reason}`.

  Scenarios should be deterministic given the same model + cases; the
  runner records pass rate over time so non-determinism shows up as
  flakiness in the report.
  """

  @type case_id :: String.t()
  @type result :: {:pass, map()} | {:fail, map()} | {:skip, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback cases() :: [map()]
  @callback run(map(), keyword()) :: result()
end
