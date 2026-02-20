defmodule Hive.CLI.Errors do
  @moduledoc """
  Enhanced error messages with helpful suggestions and context.
  """

  @doc """
  Formats an error with context and suggestions.
  """
  def format_error(error_type, context \\ %{})

  def format_error(:store_not_initialized, _context) do
    """
    Error: Hive store not initialized

    The hive workspace hasn't been set up yet. To fix this:

      1. Initialize a new hive workspace:
         $ hive init ~/my-hive

      2. Or set HIVE_PATH to an existing workspace:
         $ export HIVE_PATH=~/my-hive

    For more help, run: hive doctor
    """
  end

  def format_error(:no_combs, _context) do
    """
    Error: No combs registered

    You need to register at least one codebase before creating quests.

    Quick start:
      $ hive comb add /path/to/repo --auto

    Or manual setup:
      $ hive comb add /path/to/repo --name myproject --validation-command "mix test"

    For more options, run: hive comb add --help
    """
  end

  def format_error(:quest_not_found, %{quest_id: id}) do
    """
    Error: Quest not found: #{id}

    The quest ID doesn't exist or may have been deleted.

    To see available quests:
      $ hive quest list

    To create a new quest:
      $ hive quest new "Build feature X"
    """
  end

  def format_error(:job_not_found, %{job_id: id}) do
    """
    Error: Job not found: #{id}

    The job ID doesn't exist or may have been deleted.

    To see available jobs:
      $ hive jobs list

    To see jobs for a specific quest:
      $ hive quest show <quest-id>
    """
  end

  def format_error(:bee_not_found, %{bee_id: id}) do
    """
    Error: Bee not found: #{id}

    The bee may have already stopped or crashed.

    To see active bees:
      $ hive bee list

    To spawn a new bee:
      $ hive bee spawn --job <job-id> --comb <comb-id>
    """
  end

  def format_error(:comb_not_found, %{comb_id: id}) do
    """
    Error: Comb not found: #{id}

    The comb doesn't exist or may have been removed.

    To see registered combs:
      $ hive comb list

    To add a new comb:
      $ hive comb add /path/to/repo --auto
    """
  end

  def format_error(:git_not_found, %{path: path}) do
    """
    Error: Not a git repository: #{path}

    The directory must be a git repository to be registered as a comb.

    To initialize git:
      $ cd #{path}
      $ git init
      $ git add .
      $ git commit -m "Initial commit"

    Then try again:
      $ hive comb add #{path}
    """
  end

  def format_error(:validation_failed, %{job_id: id, output: output}) do
    """
    Error: Job validation failed: #{id}

    Validation command output:
    #{indent(output, 2)}

    To see full job details:
      $ hive jobs show #{id}

    To retry with fixes:
      $ hive bee revive --id <bee-id>
    """
  end

  def format_error(:context_overflow, %{bee_id: id, percentage: pct}) do
    """
    Warning: Bee context usage critical: #{id}

    Context usage: #{Float.round(pct, 1)}% (threshold: 45%)

    The bee is approaching context limits and may need a handoff.

    To create a handoff:
      $ hive handoff create --bee #{id}

    To check context status:
      $ hive bee context #{id}
    """
  end

  def format_error(:budget_exceeded, %{quest_id: id, budget: budget, spent: spent}) do
    """
    Error: Quest budget exceeded: #{id}

    Budget: $#{Float.round(budget, 2)}
    Spent:  $#{Float.round(spent, 2)}

    The quest has exceeded its cost budget and cannot continue.

    To increase the budget:
      $ hive budget --quest #{id} --set #{Float.round(budget * 1.5, 2)}

    To check costs:
      $ hive costs summary
    """
  end

  def format_error(:no_model_available, %{job_type: type}) do
    """
    Error: No suitable model available for job type: #{type}

    No model plugins are configured or available for this job type.

    To check available models:
      $ hive plugin list

    To configure a model:
      Edit .hive/config.toml and set the default model plugin
    """
  end

  def format_error(:verification_pending, %{job_id: id}) do
    """
    Notice: Job verification pending: #{id}

    The job has completed but verification hasn't run yet.

    To manually verify:
      $ hive verify --job #{id}

    To start automatic verification:
      $ hive drone --verify
    """
  end

  def format_error(error_type, context) do
    """
    Error: #{error_type}

    Context: #{inspect(context)}

    For help, run: hive --help
    Or check the documentation: https://github.com/mpurdon/hive
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
