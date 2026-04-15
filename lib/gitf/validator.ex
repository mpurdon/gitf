defmodule GiTF.Validator do
  @moduledoc """
  Validates ghost output after completion.

  Runs an optional custom validation command (e.g. `mix test`) and
  optionally a headless Claude assessment of the diff against the
  op description. Pure context module.
  """

  require Logger

  alias GiTF.Archive

  @doc """
  Validates a completed ghost's work.

  1. Runs `validation_command` in the shell worktree if the sector has one.
  2. Runs headless Claude validation to assess the diff.

  Returns `{:ok, :pass}`, `{:ok, :skip}`, or `{:error, reason, details}`.
  """
  @spec validate(String.t(), map(), String.t()) ::
          {:ok, atom()} | {:error, term()} | {:error, term(), term()}
  def validate(_ghost_id, op, shell_id) do
    with {:ok, shell} <- fetch_cell(shell_id),
         {:ok, sector} <- fetch_sector(shell.sector_id) do
      results = []

      # Run custom validation command if configured
      results =
        if sector.validation_command do
          case run_custom_validation(shell, sector.validation_command) do
            :ok -> results
            {:error, reason} -> [{:error, :custom_validation_failed, reason} | results]
          end
        else
          results
        end

      # Run Claude validation
      results =
        case run_claude_validation(op, shell) do
          {:ok, :pass} -> results
          {:ok, :skip} -> results
          {:error, reason, details} -> [{:error, reason, details} | results]
          _ -> results
        end

      case Enum.find(results, &match?({:error, _, _}, &1)) do
        nil -> {:ok, :pass}
        {:error, reason, details} -> {:error, reason, details}
      end
    end
  end

  @validation_timeout_ms 120_000

  @doc "Runs a custom shell command in the shell worktree."
  @spec run_custom_validation(map(), String.t()) :: :ok | {:error, String.t()}
  def run_custom_validation(shell, command) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command],
          cd: shell.worktree_path,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )
      end)

    case Task.yield(task, @validation_timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, exit_code}} ->
        {:error, "Command failed (exit #{exit_code}): #{String.slice(output, 0, 500)}"}

      nil ->
        {:error, "Validation command timed out after #{div(@validation_timeout_ms, 1000)}s"}
    end
  rescue
    e -> {:error, "Validation command error: #{Exception.message(e)}"}
  end

  @doc "Runs model validation to assess whether the diff solves the op."
  @spec run_claude_validation(map(), map()) ::
          {:ok, :pass} | {:ok, :skip} | {:error, term(), term()}
  def run_claude_validation(op, shell) do
    case get_diff(shell) do
      {:ok, ""} ->
        {:ok, :skip}

      {:ok, diff} ->
        prompt = build_validation_prompt(op, diff)

        if GiTF.Runtime.ModelResolver.api_mode?() do
          # API mode: use generate_text (no tools needed for validation)
          case GiTF.Runtime.Models.generate_text(prompt, model: "haiku") do
            {:ok, output} -> parse_verdict(output)
            {:error, _} -> {:ok, :skip}
          end
        else
          # CLI mode: spawn headless and collect
          case GiTF.Runtime.Models.spawn_headless(prompt, shell.worktree_path) do
            {:ok, port} ->
              collect_validation_result(port)

            {:error, _reason} ->
              {:ok, :skip}
          end
        end

      {:error, _} ->
        {:ok, :skip}
    end
  rescue
    e in [ErlangError, Mint.TransportError, Mint.HTTPError] ->
      Logger.debug("Validation network error (non-fatal): #{inspect(e)}")
      {:ok, :skip}
  end

  @doc "Builds the validation prompt for Claude."
  @spec build_validation_prompt(map(), String.t()) :: String.t()
  def build_validation_prompt(op, diff) do
    description = op.description || ""

    """
    You are a code reviewer. Evaluate whether the following changes solve the task.

    ## Task
    Title: #{op.title}
    Description: #{description}

    ## Changes (git diff)
    ```
    #{String.slice(diff, 0, 8000)}
    ```

    Respond with ONLY a JSON object (no markdown fences):
    {"verdict": "pass" or "fail", "reasoning": "brief explanation", "issues": ["issue1", ...]}
    """
  end

  # -- Private -----------------------------------------------------------------

  defp fetch_cell(shell_id) do
    case Archive.get(:shells, shell_id) do
      nil -> {:error, :shell_not_found}
      shell -> {:ok, shell}
    end
  end

  defp fetch_sector(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> {:error, :sector_not_found}
      sector -> {:ok, sector}
    end
  end

  defp get_diff(shell) do
    case GiTF.Git.safe_cmd(["diff", "HEAD~1..HEAD"],
           cd: shell.worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output}

      {_, _} ->
        # Fallback: diff against the working tree
        case GiTF.Git.safe_cmd(["diff"], cd: shell.worktree_path, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _} -> {:error, output}
        end
    end
  rescue
    e in [ErlangError] ->
      Logger.debug("Git diff failed (git not available): #{inspect(e)}")
      {:error, :diff_failed}
  end

  defp collect_validation_result(port) do
    collect_validation_result(port, [], 60_000)
  end

  defp collect_validation_result(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_validation_result(port, [acc, data], timeout)

      {^port, {:exit_status, 0}} ->
        output = IO.iodata_to_binary(acc)
        parse_verdict(output)

      {^port, {:exit_status, _}} ->
        {:ok, :skip}
    after
      timeout ->
        safe_close_port(port)
        {:ok, :skip}
    end
  end

  defp parse_verdict(output) do
    # Try to extract JSON from the output
    case extract_json(output) do
      {:ok, %{"verdict" => "pass"}} ->
        {:ok, :pass}

      {:ok, %{"verdict" => "fail"} = json} ->
        issues = Map.get(json, "issues", [])
        reasoning = Map.get(json, "reasoning", "")
        {:error, :validation_failed, %{reasoning: reasoning, issues: issues}}

      _ ->
        {:ok, :skip}
    end
  end

  defp extract_json(text) do
    # Find JSON object in text
    case Regex.run(~r/\{[^{}]*"verdict"[^{}]*\}/s, text) do
      [json_str] -> Jason.decode(json_str)
      _ -> {:error, :no_json}
    end
  end

  defp safe_close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
