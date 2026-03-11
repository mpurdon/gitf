defmodule GiTF.Audit do
  @moduledoc """
  Job verification system.
  
  Verifies completed ops by running validation commands and checking
  against verification criteria.
  """

  require Logger
  alias GiTF.Archive
  alias GiTF.Quality

  @doc """
  Verifies a completed op.
  
  Runs validation command and quality checks.
  Returns {:ok, :pass | :fail, result} or {:error, reason}.
  """
  @spec verify_job(String.t(), keyword()) :: {:ok, atom(), map()} | {:error, term()}
  def verify_job(op_id, opts \\ []) do
    with {:ok, op} <- GiTF.Ops.get(op_id),
         {:ok, shell} <- get_job_cell(op),
         {:ok, sector} <- Archive.fetch(:sectors, op.sector_id) do

      # Check graduated clearance — auto-approve eligible ops
      authority_level = GiTF.Clearance.verification_level(op)

      if authority_level == :auto_approve and GiTF.Clearance.should_auto_merge?(op) do
        auto_result = %{
          op_id: op_id,
          status: "auto_approved",
          output: "Auto-approved via graduated clearance (model trust)",
          exit_code: 0,
          quality_score: nil,
          ran_at: DateTime.utc_now()
        }

        {:ok, _} = record_result(op_id, auto_result)
        update_job_verification(op_id, :pass, auto_result)
        {:ok, :pass, auto_result}
      else
        result = %{
          op_id: op_id,
          status: "running",
          output: "",
          exit_code: nil,
          quality_score: nil,
          ran_at: DateTime.utc_now()
        }

        skip_validation = Keyword.get(opts, :skip_validation_command, false)

        # Run validation command if configured (skip if already run by Validator)
        validation_result =
          if not skip_validation and Map.get(sector, :validation_command) do
            case run_validation_command(shell, sector.validation_command) do
              {:ok, output} ->
                %{result | status: "passed", output: output, exit_code: 0}
              {:error, {output, exit_code}} ->
                %{result | status: "failed", output: output, exit_code: exit_code}
            end
          else
            %{result | status: "passed", output: "No validation command configured"}
          end

        # Run quality checks
        quality_result = run_quality_checks(op_id, shell, sector)

        # Run cross-model audit if enabled
        cross_audit_result =
          if GiTF.Runtime.CrossModelAudit.enabled?(sector.id) do
            case GiTF.Runtime.CrossModelAudit.audit_job(op_id) do
              {:ok, audit} ->
                %{cross_audit_score: audit.score, cross_audit_issues: audit.issues}
              {:error, reason} ->
                Logger.warning("Cross-model audit failed for op #{op_id}: #{inspect(reason)}")
                %{cross_audit_error: inspect(reason)}
            end
          else
            %{}
          end

        # Combine results
        final_result =
          validation_result
          |> Map.merge(quality_result)
          |> Map.merge(cross_audit_result)

        # Build verification contract and evaluate
        contract = GiTF.AuditContract.build_contract(op)
        adjusted_contract = adjust_contract_thresholds(contract, authority_level)
        final_status = evaluate_contract_status(final_result, adjusted_contract)
        final_result = %{final_result | status: final_status}

        # Archive result
        {:ok, _} = record_result(op_id, final_result)

        # Update op
        status = if final_status == "passed", do: :pass, else: :fail
        update_job_verification(op_id, status, final_result)

        {:ok, status, final_result}
      end
    end
  end

  @doc """
  Gets verification status for a op.
  """
  @spec get_verification_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_verification_status(op_id) do
    case Archive.get(:ops, op_id) do
      nil -> {:error, :not_found}
      op -> 
        {:ok, %{
          status: Map.get(op, :verification_status, "pending"),
          result: Map.get(op, :audit_result),
          verified_at: Map.get(op, :verified_at)
        }}
    end
  end

  @doc """
  Records a verification result and updates the op status.
  """
  @spec record_result(String.t(), map()) :: {:ok, map()}
  def record_result(op_id, result) do
    # Archive in audit_results collection
    record = Map.put(result, :op_id, op_id)
    {:ok, vr} = Archive.insert(:audit_results, record)
    
    # Update op verification status
    case Archive.get(:ops, op_id) do
      nil -> {:error, :not_found}
      op ->
        verification_status = result.status
        updated = op
        |> Map.put(:verification_status, verification_status)
        |> Map.put(:audit_result, result[:output])
        |> Map.put(:verified_at, DateTime.utc_now())
        
        Archive.put(:ops, updated)
        {:ok, vr}
    end
  end

  @doc """
  Lists ops needing verification.
  """
  @spec jobs_needing_verification() :: [map()]
  def jobs_needing_verification do
    Archive.filter(:ops, fn op ->
      op.status == "done" and 
      Map.get(op, :verification_status, "pending") == "pending"
    end)
  end

  # Private functions

  defp get_job_cell(op) do
    case Archive.find_one(:shells, fn c -> 
      c.ghost_id == op.ghost_id and c.status == "active" 
    end) do
      nil -> {:error, :no_cell}
      shell -> {:ok, shell}
    end
  end

  @validation_timeout_ms 120_000

  defp run_validation_command(shell, command) do
    task = Task.async(fn ->
      System.cmd("sh", ["-c", command],
        cd: shell.worktree_path,
        stderr_to_stdout: true)
    end)

    case Task.yield(task, @validation_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, exit_code}} -> {:error, {output, exit_code}}
      nil -> {:error, {"Validation command timed out after #{div(@validation_timeout_ms, 1000)}s", 1}}
    end
  rescue
    e -> {:error, {Exception.message(e), 1}}
  end

  defp update_job_verification(op_id, status, result) do
    case Archive.get(:ops, op_id) do
      nil -> :error
      op ->
        verification_status = if status == :pass, do: "passed", else: "failed"
        
        updated = op
        |> Map.put(:verification_status, verification_status)
        |> Map.put(:audit_result, result.output)
        |> Map.put(:quality_score, result[:quality_score])
        |> Map.put(:verified_at, DateTime.utc_now())
        
        Archive.put(:ops, updated)
    end
  end

  defp run_quality_checks(op_id, shell, sector) do
    language = detect_language(sector)

    # Run static analysis
    static_result = case Quality.analyze_static(op_id, shell.worktree_path, language) do
      {:ok, report} -> %{static_score: report.score, static_issues: length(report.issues)}
      {:error, reason} ->
        Logger.warning("Static analysis failed for op #{op_id}: #{inspect(reason)}")
        %{static_score: 0, static_issues: 0, static_error: inspect(reason)}
    end

    # Run security scan
    security_result = case Quality.analyze_security(op_id, shell.worktree_path, language) do
      {:ok, report} -> %{security_score: report.score, security_findings: length(report.issues)}
      {:error, reason} ->
        Logger.warning("Security scan failed for op #{op_id}: #{inspect(reason)}")
        %{security_score: 0, security_findings: 0, security_error: inspect(reason)}
    end

    # Run performance benchmarks (if configured)
    performance_result = case Quality.analyze_performance(op_id, shell.worktree_path, sector) do
      {:ok, report} -> %{performance_score: report.score, performance_metrics: length(report.issues)}
      {:error, _} -> %{performance_score: nil, performance_metrics: 0}
    end

    # Calculate composite score
    composite = Quality.calculate_composite_score(op_id)

    Map.merge(static_result, security_result)
    |> Map.merge(performance_result)
    |> Map.put(:quality_score, composite)
  end

  @known_languages ~w(elixir javascript typescript python rust go ruby java)a

  defp detect_language(sector) do
    # Use metadata if available
    case Map.get(sector, :metadata) do
      %{language: lang} when is_binary(lang) ->
        atom = String.to_existing_atom(lang)
        if atom in @known_languages, do: atom, else: :unknown

      _ ->
        # Fallback: detect from path
        cond do
          File.exists?(Path.join(sector.path, "mix.exs")) -> :elixir
          File.exists?(Path.join(sector.path, "package.json")) -> :javascript
          File.exists?(Path.join(sector.path, "Cargo.toml")) -> :rust
          File.exists?(Path.join(sector.path, "requirements.txt")) -> :python
          true -> :unknown
        end
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc """
  Raises on verification failure. Useful in pipeline contexts where
  failure should halt processing.
  """
  @spec verify_job!(String.t()) :: map()
  def verify_job!(op_id) do
    case verify_job(op_id) do
      {:ok, :pass, result} -> result
      {:ok, :fail, result} -> raise "Audit failed for op #{op_id}: #{inspect(result[:output])}"
      {:error, reason} -> raise "Audit error for op #{op_id}: #{inspect(reason)}"
    end
  end

  defp adjust_contract_thresholds(contract, authority_level) do
    adjusted = GiTF.Clearance.adjusted_thresholds(contract.thresholds, authority_level)
    %{contract | thresholds: adjusted}
  end

  defp evaluate_contract_status(result, contract) do
    if result.status == "failed" do
      "failed"
    else
      case GiTF.AuditContract.evaluate(contract, result) do
        :pass -> "passed"
        {:fail, _reasons} -> "failed"
      end
    end
  end
end