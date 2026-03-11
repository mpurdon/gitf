defmodule GiTF.Runtime.CrossModelAudit do
  @moduledoc """
  Cross-model auditing for cognitive monoculture reduction.

  Uses a different LLM provider to review work done by the implementation
  model. If the implementation used Anthropic, the audit uses Google (and
  vice versa), so that a single model's blind spots don't propagate.
  """

  require Logger

  @doc """
  Selects an audit model from a different provider than the implementation model.

  Uses haiku-tier models for cost efficiency.
  """
  @spec select_audit_model(String.t() | nil) :: String.t()
  def select_audit_model(nil), do: "google:gemini-2.0-flash"

  def select_audit_model(implementation_model) do
    normalized = String.downcase(implementation_model)

    cond do
      String.contains?(normalized, "google") or String.contains?(normalized, "gemini") ->
        "anthropic:claude-haiku-4-5"

      true ->
        # Default: Anthropic models get Google audit
        "google:gemini-2.0-flash"
    end
  end

  @doc """
  Audits a completed job by having a different model review the diff.

  Fetches the job's cell, gets the git diff, builds a review prompt,
  and calls the audit model. Returns a structured audit report.
  """
  @spec audit_job(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit_job(job_id, opts \\ []) do
    with {:ok, job} <- GiTF.Jobs.get(job_id),
         {:ok, cell} <- find_cell(job),
         {:ok, diff} <- get_diff(cell) do

      if String.trim(diff) == "" do
        {:ok, %{score: 100, issues: [], severity: :none, model: "none", skipped: true}}
      else
        audit_model = Keyword.get(opts, :model) || select_audit_model(job[:assigned_model])
        prompt = build_review_prompt(job, diff)

        case GiTF.Runtime.Models.generate_text(prompt, model: audit_model) do
          {:ok, response} ->
            report = parse_audit_response(response, audit_model)
            {:ok, report}

          {:error, reason} ->
            Logger.warning("Cross-model audit failed for job #{job_id}: #{inspect(reason)}")
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Returns whether cross-model auditing is enabled for a comb.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(comb_id) do
    case GiTF.Store.get(:combs, comb_id) do
      nil -> false
      comb -> Map.get(comb, :cross_model_audit, false) == true
    end
  end

  # -- Private ---------------------------------------------------------------

  defp find_cell(job) do
    case GiTF.Store.find_one(:cells, fn c ->
      c.ghost_id == job.ghost_id and c.status == "active"
    end) do
      nil -> {:error, :no_cell}
      cell -> {:ok, cell}
    end
  end

  defp get_diff(cell) do
    case GiTF.Git.safe_cmd( ["diff", "HEAD~1"], cd: cell.worktree_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_, _} ->
        # Fallback: diff against main
        case GiTF.Git.safe_cmd( ["diff", "main"], cd: cell.worktree_path, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _} -> {:error, {:diff_failed, output}}
        end
    end
  rescue
    e -> {:error, {:diff_error, Exception.message(e)}}
  end

  defp build_review_prompt(job, diff) do
    """
    You are a code reviewer. Review the following git diff for quality, correctness, and security issues.

    ## Job Context
    Title: #{job.title}
    Description: #{job.description || "N/A"}

    ## Git Diff
    ```diff
    #{String.slice(diff, 0, 50_000)}
    ```

    ## Instructions
    Analyze the diff and respond with ONLY a JSON object:

    ```json
    {
      "score": <0-100 quality score>,
      "issues": [
        {"description": "...", "severity": "low|medium|high|critical", "file": "..."}
      ],
      "summary": "Brief overall assessment"
    }
    ```
    """
  end

  defp parse_audit_response(response, model) do
    text =
      case response do
        %{text: t} -> t
        t when is_binary(t) -> t
        other -> inspect(other)
      end

    case extract_json(text) do
      {:ok, parsed} ->
        %{
          score: parsed["score"] || 50,
          issues: parsed["issues"] || [],
          severity: infer_severity(parsed["issues"] || []),
          summary: parsed["summary"],
          model: model
        }

      :error ->
        %{
          score: 50,
          issues: [%{"description" => "Could not parse audit response", "severity" => "low"}],
          severity: :low,
          summary: text,
          model: model
        }
    end
  end

  defp extract_json(text) do
    json_str =
      case Regex.run(~r/```json\s*\n(.*?)\n\s*```/s, text) do
        [_, json] -> json
        _ -> text
      end

    case Jason.decode(json_str) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      _ -> :error
    end
  end

  defp infer_severity(issues) when is_list(issues) do
    severities = Enum.map(issues, fn i -> Map.get(i, "severity", "low") end)

    cond do
      "critical" in severities -> :critical
      "high" in severities -> :high
      "medium" in severities -> :medium
      true -> :low
    end
  end

  defp infer_severity(_), do: :low
end
