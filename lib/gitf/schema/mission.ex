defmodule GiTF.Schema.Mission do
  @moduledoc """
  Domain struct for a mission -- the top-level unit of work in GiTF.

  A mission captures a user goal, tracks its lifecycle through phases
  (pending -> research -> planning -> implementation -> completed),
  and owns the ops that carry out the work.

  ## Status vs. current_phase

  `status` and `current_phase` deliberately diverge during async
  post-processing: once `publish` lands, `status` flips to `"completed"`
  (user-visible done) while `current_phase` continues through `"scoring"`
  and then to `"completed"`. The `post_processing_status` field
  (`nil | "pending" | "done" | "failed"`) tracks the background scoring +
  learning loop independently of the user-facing status.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          goal: String.t(),
          status: String.t(),
          sector_id: String.t() | nil,
          current_phase: String.t(),
          phase_advance_seq: non_neg_integer(),
          priority: atom(),
          priority_source: atom() | nil,
          priority_set_at: DateTime.t() | nil,
          review_plan: boolean(),
          research_summary: String.t() | nil,
          implementation_plan: map() | nil,
          artifacts: map(),
          phase_jobs: map(),
          post_processing_status: String.t() | nil,
          cost_cap_usd: float() | nil,
          issue_ref: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :goal]

  defstruct [
    :id,
    :name,
    :goal,
    :sector_id,
    :research_summary,
    :implementation_plan,
    :priority_source,
    :priority_set_at,
    :inserted_at,
    :updated_at,
    status: "pending",
    current_phase: "pending",
    phase_advance_seq: 0,
    priority: :normal,
    review_plan: false,
    artifacts: %{},
    phase_jobs: %{},
    post_processing_status: nil,
    cost_cap_usd: nil,
    issue_ref: nil
  ]

  @required_keys [:goal]

  @doc """
  Creates a new mission as a plain map suitable for Archive storage.

  Required: `:goal`.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    goal = attrs[:goal] || attrs["goal"]

    if is_nil(goal) or goal == "" do
      {:error, {:missing_fields, @required_keys}}
    else
      {:ok,
       %{
         id: attrs[:id] || attrs["id"],
         name: attrs[:name] || attrs["name"],
         goal: goal,
         status: attrs[:status] || attrs["status"] || "pending",
         sector_id: attrs[:sector_id] || attrs["sector_id"],
         current_phase: attrs[:current_phase] || attrs["current_phase"] || "pending",
         phase_advance_seq: attrs[:phase_advance_seq] || attrs["phase_advance_seq"] || 0,
         priority: attrs[:priority] || attrs["priority"] || :normal,
         priority_source: attrs[:priority_source] || attrs["priority_source"],
         priority_set_at: attrs[:priority_set_at] || attrs["priority_set_at"],
         review_plan: attrs[:review_plan] || attrs["review_plan"] || false,
         research_summary: attrs[:research_summary] || attrs["research_summary"],
         implementation_plan: attrs[:implementation_plan] || attrs["implementation_plan"],
         artifacts: attrs[:artifacts] || attrs["artifacts"] || %{},
         phase_jobs: attrs[:phase_jobs] || attrs["phase_jobs"] || %{},
         post_processing_status: attrs[:post_processing_status] || attrs["post_processing_status"],
         cost_cap_usd: attrs[:cost_cap_usd] || attrs["cost_cap_usd"],
         issue_ref: attrs[:issue_ref] || attrs["issue_ref"]
       }}
    end
  end

  @doc """
  Converts a raw map (e.g. from Archive) into a `%Mission{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) when is_map(raw) do
    %__MODULE__{
      id: raw[:id] || raw["id"],
      name: raw[:name] || raw["name"],
      goal: raw[:goal] || raw["goal"],
      status: raw[:status] || raw["status"] || "pending",
      sector_id: raw[:sector_id] || raw["sector_id"],
      current_phase: raw[:current_phase] || raw["current_phase"] || "pending",
      phase_advance_seq: raw[:phase_advance_seq] || raw["phase_advance_seq"] || 0,
      priority: raw[:priority] || raw["priority"] || :normal,
      priority_source: raw[:priority_source] || raw["priority_source"],
      priority_set_at: raw[:priority_set_at] || raw["priority_set_at"],
      review_plan: raw[:review_plan] || raw["review_plan"] || false,
      research_summary: raw[:research_summary] || raw["research_summary"],
      implementation_plan: raw[:implementation_plan] || raw["implementation_plan"],
      artifacts: raw[:artifacts] || raw["artifacts"] || %{},
      phase_jobs: raw[:phase_jobs] || raw["phase_jobs"] || %{},
      post_processing_status: raw[:post_processing_status] || raw["post_processing_status"],
      cost_cap_usd: raw[:cost_cap_usd] || raw["cost_cap_usd"],
      issue_ref: raw[:issue_ref] || raw["issue_ref"],
      inserted_at: raw[:inserted_at] || raw["inserted_at"],
      updated_at: raw[:updated_at] || raw["updated_at"]
    }
  end
end
