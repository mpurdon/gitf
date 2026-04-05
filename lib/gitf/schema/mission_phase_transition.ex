defmodule GiTF.Schema.MissionPhaseTransition do
  @moduledoc """
  Schema for mission phase transitions.

  Tracks when a mission moves between phases (pending → research → planning → implementation).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          mission_id: String.t(),
          from_phase: String.t(),
          to_phase: String.t(),
          reason: String.t() | nil,
          metadata: map() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  defstruct [
    :id,
    :mission_id,
    :from_phase,
    :to_phase,
    :reason,
    :metadata,
    :inserted_at,
    :updated_at
  ]
end
