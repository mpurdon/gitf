defmodule GiTF.Schema.Op do
  @moduledoc """
  Domain struct for an op -- a discrete unit of work within a mission.

  An op is assigned to a ghost for execution. It carries classification
  metadata (type, complexity, recommended model), verification criteria,
  and phase/recon information.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t(),
          description: String.t() | nil,
          status: String.t(),
          mission_id: String.t(),
          sector_id: String.t(),
          ghost_id: String.t() | nil,
          op_type: String.t() | nil,
          complexity: String.t(),
          recommended_model: String.t() | nil,
          assigned_model: String.t() | nil,
          model_selection_reason: String.t() | nil,
          verification_criteria: list(),
          estimated_context_tokens: non_neg_integer() | nil,
          phase_job: boolean(),
          phase: String.t() | nil,
          strategy: String.t() | nil,
          acceptance_criteria: list(),
          target_files: list(),
          verification_status: String.t(),
          audit_result: map() | nil,
          verified_at: DateTime.t() | nil,
          risk_level: atom(),
          retry_count: non_neg_integer(),
          verification_contract: map() | nil,
          recon: boolean(),
          scout_for: String.t() | nil,
          scout_findings: map() | nil,
          triage_result: map() | nil,
          skip_verification: boolean(),
          priority: atom() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :title, :mission_id, :sector_id]

  defstruct [
    :id,
    :title,
    :description,
    :mission_id,
    :sector_id,
    :ghost_id,
    :op_type,
    :recommended_model,
    :assigned_model,
    :model_selection_reason,
    :estimated_context_tokens,
    :phase,
    :audit_result,
    :verified_at,
    :verification_contract,
    :scout_for,
    :scout_findings,
    :triage_result,
    :priority,
    :strategy,
    :inserted_at,
    :updated_at,
    status: "pending",
    complexity: "moderate",
    verification_criteria: [],
    phase_job: false,
    acceptance_criteria: [],
    target_files: [],
    verification_status: "pending",
    risk_level: :low,
    retry_count: 0,
    recon: false,
    skip_verification: false
  ]

  @required_keys [:title, :mission_id, :sector_id]

  @doc """
  Creates a new op as a plain map suitable for Archive storage.

  Required: `:title`, `:mission_id`, `:sector_id`.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    missing =
      Enum.filter(@required_keys, fn key ->
        val = attrs[key] || attrs[Atom.to_string(key)]
        is_nil(val) or val == ""
      end)

    if missing != [] do
      {:error, {:missing_fields, missing}}
    else
      {:ok,
       %{
         id: attrs[:id] || attrs["id"],
         title: attrs[:title] || attrs["title"],
         description: attrs[:description] || attrs["description"],
         status: attrs[:status] || attrs["status"] || "pending",
         mission_id: attrs[:mission_id] || attrs["mission_id"],
         sector_id: attrs[:sector_id] || attrs["sector_id"],
         ghost_id: attrs[:ghost_id] || attrs["ghost_id"],
         op_type: attrs[:op_type] || attrs["op_type"],
         complexity: attrs[:complexity] || attrs["complexity"] || "moderate",
         recommended_model: attrs[:recommended_model] || attrs["recommended_model"],
         assigned_model: attrs[:assigned_model] || attrs["assigned_model"],
         model_selection_reason:
           attrs[:model_selection_reason] || attrs["model_selection_reason"],
         verification_criteria:
           attrs[:verification_criteria] || attrs["verification_criteria"] || [],
         estimated_context_tokens:
           attrs[:estimated_context_tokens] || attrs["estimated_context_tokens"],
         phase_job: attrs[:phase_job] || attrs["phase_job"] || false,
         phase: attrs[:phase] || attrs["phase"],
         strategy: attrs[:strategy] || attrs["strategy"],
         acceptance_criteria: attrs[:acceptance_criteria] || attrs["acceptance_criteria"] || [],
         target_files: attrs[:target_files] || attrs["target_files"] || [],
         verification_status:
           attrs[:verification_status] || attrs["verification_status"] || "pending",
         audit_result: attrs[:audit_result] || attrs["audit_result"],
         verified_at: attrs[:verified_at] || attrs["verified_at"],
         risk_level: attrs[:risk_level] || attrs["risk_level"] || :low,
         retry_count: attrs[:retry_count] || attrs["retry_count"] || 0,
         verification_contract: attrs[:verification_contract] || attrs["verification_contract"],
         recon: attrs[:recon] || attrs["recon"] || false,
         scout_for: attrs[:scout_for] || attrs["scout_for"],
         scout_findings: attrs[:scout_findings] || attrs["scout_findings"],
         triage_result: attrs[:triage_result] || attrs["triage_result"],
         skip_verification: attrs[:skip_verification] || attrs["skip_verification"] || false,
         priority: attrs[:priority] || attrs["priority"]
       }}
    end
  end

  @doc """
  Converts a raw map (e.g. from Archive) into a `%Op{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(raw) when is_map(raw) do
    %__MODULE__{
      id: raw[:id] || raw["id"],
      title: raw[:title] || raw["title"],
      description: raw[:description] || raw["description"],
      status: raw[:status] || raw["status"] || "pending",
      mission_id: raw[:mission_id] || raw["mission_id"],
      sector_id: raw[:sector_id] || raw["sector_id"],
      ghost_id: raw[:ghost_id] || raw["ghost_id"],
      op_type: raw[:op_type] || raw["op_type"],
      complexity: raw[:complexity] || raw["complexity"] || "moderate",
      recommended_model: raw[:recommended_model] || raw["recommended_model"],
      assigned_model: raw[:assigned_model] || raw["assigned_model"],
      model_selection_reason: raw[:model_selection_reason] || raw["model_selection_reason"],
      verification_criteria: raw[:verification_criteria] || raw["verification_criteria"] || [],
      estimated_context_tokens: raw[:estimated_context_tokens] || raw["estimated_context_tokens"],
      phase_job: raw[:phase_job] || raw["phase_job"] || false,
      phase: raw[:phase] || raw["phase"],
      strategy: raw[:strategy] || raw["strategy"],
      acceptance_criteria: raw[:acceptance_criteria] || raw["acceptance_criteria"] || [],
      target_files: raw[:target_files] || raw["target_files"] || [],
      verification_status: raw[:verification_status] || raw["verification_status"] || "pending",
      audit_result: raw[:audit_result] || raw["audit_result"],
      verified_at: raw[:verified_at] || raw["verified_at"],
      risk_level: raw[:risk_level] || raw["risk_level"] || :low,
      retry_count: raw[:retry_count] || raw["retry_count"] || 0,
      verification_contract: raw[:verification_contract] || raw["verification_contract"],
      recon: raw[:recon] || raw["recon"] || false,
      scout_for: raw[:scout_for] || raw["scout_for"],
      scout_findings: raw[:scout_findings] || raw["scout_findings"],
      triage_result: raw[:triage_result] || raw["triage_result"],
      skip_verification: raw[:skip_verification] || raw["skip_verification"] || false,
      priority: raw[:priority] || raw["priority"],
      inserted_at: raw[:inserted_at] || raw["inserted_at"],
      updated_at: raw[:updated_at] || raw["updated_at"]
    }
  end
end
