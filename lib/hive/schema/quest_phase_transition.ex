defmodule Hive.Schema.QuestPhaseTransition do
  @moduledoc """
  Schema for quest phase transitions.
  
  Tracks when a quest moves between phases (pending → research → planning → implementation).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          quest_id: String.t(),
          from_phase: String.t(),
          to_phase: String.t(),
          reason: String.t() | nil,
          metadata: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :quest_id,
    :from_phase,
    :to_phase,
    :reason,
    :metadata,
    :inserted_at,
    :updated_at
  ]
end