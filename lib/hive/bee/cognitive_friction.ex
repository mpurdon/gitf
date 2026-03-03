defmodule Hive.Bee.CognitiveFriction do
  @moduledoc """
  Dynamic cognitive friction for bees.

  Adjusts how much a bee must "think before acting" based on job risk level.
  High-risk jobs get mandatory confirmation prompts; low-risk jobs get
  streamlined instructions with no extra friction.
  """

  @doc """
  Returns extra priming instructions based on risk level.

  Appended to the bee's Rules section during priming so the bee
  adjusts its behaviour to match the risk of the job.
  """
  @spec friction_instructions(atom()) :: String.t()
  def friction_instructions(:low), do: ""

  def friction_instructions(:medium) do
    "- Before modifying config files, explain your reasoning."
  end

  def friction_instructions(:high) do
    """
    - Before any file write, state what you plan to change and why.
    - Send a waggle to queen with subject 'clarification_needed' if instructions are ambiguous: \
    `hive waggle send --to queen --subject "clarification_needed" --body "<question>"`\
    """
    |> String.trim()
  end

  def friction_instructions(:critical) do
    """
    - Do NOT write any files. Produce a detailed plan as your output.
    - All changes must be reviewed by the queen before execution.
    - Send a waggle to queen with subject 'clarification_needed' for any ambiguity: \
    `hive waggle send --to queen --subject "clarification_needed" --body "<question>"`\
    """
    |> String.trim()
  end

  # Fallback for unknown/nil risk levels
  def friction_instructions(_), do: ""

  @doc """
  Returns whether the given risk level requires confirmation before acting.
  """
  @spec requires_confirmation?(atom()) :: boolean()
  def requires_confirmation?(:high), do: true
  def requires_confirmation?(:critical), do: true
  def requires_confirmation?(_), do: false
end
