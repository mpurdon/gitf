defmodule GiTF.Verification.Driver do
  @moduledoc """
  Behaviour for modality-specific verification drivers.

  A driver knows how to *exercise the artifact through the interface its real
  consumer uses* and capture a transcript for the LLM judge:

    * `:cli` / `:library` / `:tui` → run commands in a sandboxed shell
      (`Driver.Shell`) and capture stdout/stderr/exit codes.
    * `:http` / `:service` → drive HTTP endpoints (`Driver.Http`).
    * `:web` → browser automation (future).
    * `:desktop` → xcodebuild/XCUITest + accessibility tree (future).

  This is the generalization of "visual verification": the browser is just the
  `:web` driver; the terminal is the `:cli` driver. Every modality reduces to
  "drive the real interface, capture evidence, judge the behaviour."
  """

  @typedoc "A scenario: a named holdout user-story with steps and a prose expectation."
  @type scenario :: %{
          required(:name) => String.t(),
          required(:expect) => String.t(),
          optional(:steps) => [String.t()],
          optional(:input) => String.t(),
          optional(:setup) => [String.t()]
        }

  @typedoc "Where/how to run: cwd, sector, risk level, env."
  @type context :: %{
          required(:cwd) => String.t(),
          optional(:sector_id) => String.t(),
          optional(:risk_level) => atom()
        }

  @typedoc "Captured evidence for the judge."
  @type transcript :: %{
          required(:ok) => boolean(),
          required(:text) => String.t(),
          optional(:exit_code) => integer() | nil
        }

  @callback run(scenario(), context()) :: transcript()

  @doc "Resolves the driver module for a modality string/atom."
  @spec for_modality(String.t() | atom()) :: {:ok, module()} | {:error, :unknown_modality}
  def for_modality(modality) when is_atom(modality),
    do: for_modality(Atom.to_string(modality))

  def for_modality(modality) when is_binary(modality) do
    case modality do
      m when m in ["cli", "library", "tui", "script"] -> {:ok, GiTF.Verification.Driver.Shell}
      m when m in ["http", "service", "server", "api"] -> {:ok, GiTF.Verification.Driver.Http}
      _ -> {:error, :unknown_modality}
    end
  end
end
