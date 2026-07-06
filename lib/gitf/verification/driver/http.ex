defmodule GiTF.Verification.Driver.Http do
  @moduledoc """
  HTTP / service driver.

  For a running service, a scenario's `steps` are HTTP probes expressed as
  shell commands (curl/httpie) — this driver runs them through the sandboxed
  shell and captures responses for the judge. Keeping the transport as shell
  commands means the scenario author controls headers/auth/body explicitly and
  the same holdout-scenario format works whether the consumer is a terminal or
  an HTTP client. A future revision can add a structured request runner.
  """

  @behaviour GiTF.Verification.Driver

  @impl true
  def run(scenario, context) do
    GiTF.Verification.Driver.Shell.run(scenario, context)
  end
end
