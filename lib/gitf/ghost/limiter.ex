defmodule GiTF.Ghost.Limiter do
  @moduledoc """
  Dynamic cognitive friction for ghosts.

  Adjusts how much a ghost must "think before acting" based on op risk level.
  High-risk ops get mandatory confirmation prompts; low-risk ops get
  streamlined instructions with no extra friction.
  """

  @doc """
  Returns extra priming instructions based on risk level.

  Appended to the ghost's Rules section during priming so the ghost
  adjusts its behaviour to match the risk of the op.
  """
  @spec friction_instructions(atom()) :: String.t()
  def friction_instructions(:low), do: ""

  def friction_instructions(:medium) do
    "- Before modifying config files, explain your reasoning."
  end

  def friction_instructions(:high) do
    """
    - Before any file write, state what you plan to change and why.
    - Send a link_msg to queen with subject 'clarification_needed' if instructions are ambiguous: \
    `gitf link send --to queen --subject "clarification_needed" --body "<question>"`\
    """
    |> String.trim()
  end

  def friction_instructions(:critical) do
    """
    - Do NOT write any files. Produce a detailed plan as your output.
    - All changes must be reviewed by the queen before execution.
    - Send a link_msg to queen with subject 'clarification_needed' for any ambiguity: \
    `gitf link send --to queen --subject "clarification_needed" --body "<question>"`\
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
