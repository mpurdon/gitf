defmodule GiTF.CLI.Errors do
  @moduledoc """
  Enhanced error messages with helpful suggestions and context.
  """

  @doc """
  Formats an error with context and suggestions.
  """
  def format_error(error_type, context \\ %{})

  def format_error(:store_not_initialized, _context) do
    """
    Error: GiTF store not initialized

    The gitf workspace hasn't been set up yet. To fix this:

      1. Initialize a new gitf workspace:
         $ section init ~/my-section

      2. Or set GITF_PATH to an existing workspace:
         $ export GITF_PATH=~/my-section

    For more help, run: section medic
    """
  end

  def format_error(:no_sectors, _context) do
    """
    Error: No sectors registered

    You need to register at least one codebase before creating missions.

    Quick start:
      $ section sector add /path/to/repo --auto

    Or manual setup:
      $ section sector add /path/to/repo --name myproject --validation-command "mix test"

    For more options, run: section sector add --help
    """
  end

  def format_error(:quest_not_found, %{mission_id: id}) do
    """
    Error: Quest not found: #{id}

    The mission ID doesn't exist or may have been deleted.

    To see available missions:
      $ section mission list

    To create a new mission:
      $ section mission new "Build feature X"
    """
  end

  def format_error(:job_not_found, %{op_id: id}) do
    """
    Error: Job not found: #{id}

    The op ID doesn't exist or may have been deleted.

    To see available ops:
      $ section ops list

    To see ops for a specific mission:
      $ section mission show <mission-id>
    """
  end

  def format_error(:ghost_not_found, %{ghost_id: id}) do
    """
    Error: Ghost not found: #{id}

    The ghost may have already stopped or crashed.

    To see active ghosts:
      $ section ghost list

    To spawn a new ghost:
      $ section ghost spawn --op <op-id> --sector <sector-id>
    """
  end

  def format_error(:sector_not_found, %{sector_id: id}) do
    """
    Error: Sector not found: #{id}

    The sector doesn't exist or may have been removed.

    To see registered sectors:
      $ section sector list

    To add a new sector:
      $ section sector add /path/to/repo --auto
    """
  end

  def format_error(:git_not_found, %{path: path}) do
    """
    Error: Not a git repository: #{path}

    The directory must be a git repository to be registered as a sector.

    To initialize git:
      $ cd #{path}
      $ git init
      $ git add .
      $ git commit -m "Initial commit"

    Then try again:
      $ section sector add #{path}
    """
  end

  def format_error(:validation_failed, %{op_id: id, output: output}) do
    """
    Error: Job validation failed: #{id}

    Validation command output:
    #{indent(output, 2)}

    To see full op details:
      $ section ops show #{id}

    To retry with fixes:
      $ section ghost revive --id <ghost-id>
    """
  end

  def format_error(:context_overflow, %{ghost_id: id, percentage: pct}) do
    """
    Warning: Ghost context usage critical: #{id}

    Context usage: #{Float.round(pct, 1)}% (threshold: 45%)

    The ghost is approaching context limits and may need a transfer.

    To create a transfer:
      $ section transfer create --ghost #{id}

    To check context status:
      $ section ghost context #{id}
    """
  end

  def format_error(:budget_exceeded, %{mission_id: id, budget: budget, spent: spent}) do
    """
    Error: Quest budget exceeded: #{id}

    Budget: $#{Float.round(budget, 2)}
    Spent:  $#{Float.round(spent, 2)}

    The mission has exceeded its cost budget and cannot continue.

    To increase the budget:
      $ section budget --mission #{id} --set #{Float.round(budget * 1.5, 2)}

    To check costs:
      $ section costs summary
    """
  end

  def format_error(:no_model_available, %{op_type: type}) do
    """
    Error: No suitable model available for op type: #{type}

    No model plugins are configured or available for this op type.

    To check available models:
      $ section plugin list

    To configure a model:
      Edit .gitf/config.toml and set the default model plugin
    """
  end

  def format_error(:verification_pending, %{op_id: id}) do
    """
    Notice: Job verification pending: #{id}

    The op has completed but verification hasn't run yet.

    To manually verify:
      $ section verify --op #{id}

    To start automatic verification:
      $ section tachikoma --verify
    """
  end

  def format_error(error_type, context) do
    """
    Error: #{error_type}

    Context: #{inspect(context)}

    For help, run: section --help
    Or check the documentation: https://github.com/mpurdon/gitf
    """
  end

  defp indent(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map(&(padding <> &1))
    |> Enum.join("\n")
  end
end
