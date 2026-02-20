defmodule Hive.Verification do
  @moduledoc """
  Job verification system.
  
  Verifies completed jobs by running validation commands and checking
  against verification criteria.
  """

  require Logger
  alias Hive.Store
  alias Hive.Quality

  @doc """
  Verifies a completed job.
  
  Runs validation command and quality checks.
  Returns {:ok, :pass | :fail, result} or {:error, reason}.
  """
  @spec verify_job(String.t()) :: {:ok, atom(), map()} | {:error, term()}
  def verify_job(job_id) do
    with {:ok, job} <- Hive.Jobs.get(job_id),
         {:ok, cell} <- get_job_cell(job),
         {:ok, comb} <- Store.fetch(:combs, job.comb_id) do
      
      result = %{
        job_id: job_id,
        status: "running",
        output: "",
        exit_code: nil,
        quality_score: nil,
        ran_at: DateTime.utc_now()
      }
      
      # Run validation command if configured
      validation_result = 
        if Map.get(comb, :validation_command) do
          case run_validation_command(cell, comb.validation_command) do
            {:ok, output} ->
              %{result | status: "passed", output: output, exit_code: 0}
            {:error, {output, exit_code}} ->
              %{result | status: "failed", output: output, exit_code: exit_code}
          end
        else
          %{result | status: "passed", output: "No validation command configured"}
        end
      
      # Run quality checks
      quality_result = run_quality_checks(job_id, cell, comb)
      
      # Combine results
      final_result = Map.merge(validation_result, quality_result)
      
      # Determine overall status
      final_status = determine_status(final_result, comb)
      final_result = %{final_result | status: final_status}
      
      # Store result
      {:ok, _} = record_result(job_id, final_result)
      
      # Update job
      status = if final_status == "passed", do: :pass, else: :fail
      update_job_verification(job_id, status, final_result)
      
      {:ok, status, final_result}
    end
  end

  @doc """
  Gets verification status for a job.
  """
  @spec get_verification_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_verification_status(job_id) do
    case Store.get(:jobs, job_id) do
      nil -> {:error, :not_found}
      job -> 
        {:ok, %{
          status: Map.get(job, :verification_status, "pending"),
          result: Map.get(job, :verification_result),
          verified_at: Map.get(job, :verified_at)
        }}
    end
  end

  @doc """
  Records a verification result and updates the job status.
  """
  @spec record_result(String.t(), map()) :: {:ok, map()}
  def record_result(job_id, result) do
    # Store in verification_results collection
    record = Map.put(result, :job_id, job_id)
    {:ok, vr} = Store.insert(:verification_results, record)
    
    # Update job verification status
    case Store.get(:jobs, job_id) do
      nil -> {:error, :not_found}
      job ->
        verification_status = result.status
        updated = job
        |> Map.put(:verification_status, verification_status)
        |> Map.put(:verification_result, result[:output])
        |> Map.put(:verified_at, DateTime.utc_now())
        
        Store.put(:jobs, updated)
        {:ok, vr}
    end
  end

  @doc """
  Lists jobs needing verification.
  """
  @spec jobs_needing_verification() :: [map()]
  def jobs_needing_verification do
    Store.filter(:jobs, fn job ->
      job.status == "done" and 
      Map.get(job, :verification_status, "pending") == "pending"
    end)
  end

  # Private functions

  defp get_job_cell(job) do
    case Store.find_one(:cells, fn c -> 
      c.bee_id == job.bee_id and c.status == "active" 
    end) do
      nil -> {:error, :no_cell}
      cell -> {:ok, cell}
    end
  end

  defp run_validation_command(cell, command) do
    case System.cmd("sh", ["-c", command], 
           cd: cell.worktree_path, 
           stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {output, exit_code}}
    end
  rescue
    e -> {:error, {Exception.message(e), 1}}
  end

  defp update_job_verification(job_id, status, result) do
    case Store.get(:jobs, job_id) do
      nil -> :error
      job ->
        verification_status = if status == :pass, do: "passed", else: "failed"
        
        updated = job
        |> Map.put(:verification_status, verification_status)
        |> Map.put(:verification_result, result.output)
        |> Map.put(:quality_score, result[:quality_score])
        |> Map.put(:verified_at, DateTime.utc_now())
        
        Store.put(:jobs, updated)
    end
  end

  defp run_quality_checks(job_id, cell, comb) do
    language = detect_language(comb)
    
    # Run static analysis
    static_result = case Quality.analyze_static(job_id, cell.worktree_path, language) do
      {:ok, report} -> %{static_score: report.score, static_issues: length(report.issues)}
      {:error, _} -> %{static_score: nil, static_issues: 0}
    end
    
    # Run security scan
    security_result = case Quality.analyze_security(job_id, cell.worktree_path, language) do
      {:ok, report} -> %{security_score: report.score, security_findings: length(report.issues)}
      {:error, _} -> %{security_score: nil, security_findings: 0}
    end
    
    # Run performance benchmarks (if configured)
    performance_result = case Quality.analyze_performance(job_id, cell.worktree_path, comb) do
      {:ok, report} -> %{performance_score: report.score, performance_metrics: length(report.issues)}
      {:error, _} -> %{performance_score: nil, performance_metrics: 0}
    end
    
    # Calculate composite score
    composite = Quality.calculate_composite_score(job_id)
    
    Map.merge(static_result, security_result)
    |> Map.merge(performance_result)
    |> Map.put(:quality_score, composite)
  end

  defp detect_language(comb) do
    # Use metadata if available
    case Map.get(comb, :metadata) do
      %{language: lang} when is_binary(lang) ->
        String.to_atom(lang)
      
      _ ->
        # Fallback: detect from path
        cond do
          File.exists?(Path.join(comb.path, "mix.exs")) -> :elixir
          File.exists?(Path.join(comb.path, "package.json")) -> :javascript
          File.exists?(Path.join(comb.path, "Cargo.toml")) -> :rust
          File.exists?(Path.join(comb.path, "requirements.txt")) -> :python
          true -> :unknown
        end
    end
  end

  defp determine_status(result, comb) do
    thresholds = Quality.get_thresholds(comb.id)
    
    cond do
      result.status == "failed" -> "failed"
      result[:security_score] && result.security_score < thresholds.security -> "failed"
      result[:performance_score] && result.performance_score < thresholds.performance -> "failed"
      result[:quality_score] && result.quality_score < thresholds.composite -> "failed"
      true -> "passed"
    end
  end
end