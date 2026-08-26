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
          case run_custom_validation(
                 shell,
                 sector.validation_command,
                 validation_timeout_ms(sector)
               ) do
            :ok -> results
            {:error, reason} -> [{:error, :custom_validation_failed, reason} | results]
          end
        else
          # Without a validation_command NOTHING is executed — the phase
          # degrades to LLM code-reading only. That must be loud, not
          # silent: it is the difference between "the change was run" and
          # "the change was read".
          Logger.warning(
            "Sector #{sector.id} (#{sector.name}) has no validation_command — " <>
              "validation is static review only; nothing was compiled or run. " <>
              "Set one via: gitf sector set #{sector.id} --validation-command \"...\""
          )

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

  # The override ceiling: nothing a ghost runs unattended gets more than half
  # an hour before we call it hung. Enforced here — the read side's owner —
  # because the write surfaces drifted: the MCP tool enforced it while the
  # CLI and HTTP API accepted an 11-day deadline the derivation path could
  # never produce.
  @max_validation_timeout_ms 1_800_000

  @doc "The override ceiling, exported for the derivation seed in Detector."
  @spec max_validation_timeout_ms() :: pos_integer()
  def max_validation_timeout_ms, do: @max_validation_timeout_ms

  @doc """
  Validates an operator-supplied validation-timeout override. Every write
  surface (CLI, HTTP API, MCP) calls this; keeping the bounds in one place
  is the point.
  """
  @spec validate_timeout_override(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def validate_timeout_override(ms)
      when is_integer(ms) and ms >= 1_000 and ms <= @max_validation_timeout_ms,
      do: {:ok, ms}

  def validate_timeout_override(ms),
    do:
      {:error,
       "validation timeout must be an integer between 1_000 and " <>
         "#{@max_validation_timeout_ms} ms, got: #{inspect(ms)}"}

  @doc """
  The validation deadline for a sector, in milliseconds.

  The single source of truth for every module that runs a sector's
  `validation_command` — this one, `GiTF.Audit`, and `GiTF.Sync.Resolver`.
  Each used to carry its own `@validation_timeout_ms 120_000`, and only this
  one consulted the sector, so a sector that opted into a longer validation
  still got 2 minutes from the other two and reported a timeout as a failed
  op. Route new callers through here rather than adding a fourth copy.
  """
  @spec validation_timeout_ms(map() | nil) :: pos_integer()
  def validation_timeout_ms(sector) when is_map(sector),
    do: sector[:validation_timeout_ms] || @validation_timeout_ms

  def validation_timeout_ms(_), do: @validation_timeout_ms

  @typedoc """
  Why a validation run did not pass.

    * `:failed`    — the command ran and returned non-zero. The ghost's code.
    * `:timeout`   — the deadline fired. Says nothing about the code.
    * `:tool_missing` — exit 126/127, a host provisioning gap.
    * `:crashed`   — the runner itself raised.
  """
  @type failure_kind :: :failed | :timeout | :tool_missing | :crashed

  @doc """
  Runs a sector's validation command. **The** way to do that — every caller
  routes through here.

  There used to be three implementations with different guarantees:
  `Audit.run_validation_command/2` was sandboxed but had no OS-level
  deadline, and `Sync.Resolver.validate_resolution/1` was not sandboxed at
  all. Whether a runaway validation was actually killed therefore depended on
  which module happened to invoke it — and an orphan does not stay in its own
  lane. A leaked probe held port :1420 and poisoned the following run once
  already. For a factory running many sectors unattended, "it depends on the
  call site" is the property to remove.

  Returns `{:ok, output}` or `{:error, kind, message, exit_code}`, where
  `message` is already shaped for a human or a prompt — tail-sliced, since
  the verdict of a shell pipeline is at the end and the head is install
  noise.
  """
  @spec run_validation(String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, failure_kind(), String.t(), integer()}
  def run_validation(cwd, command, sector, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms) || validation_timeout_ms(sector)

    # OS-enforced deadline INSIDE the sandbox. Task.shutdown/2 kills the
    # Elixir task but never the OS process behind System.cmd, so a timed-out
    # validation left its whole bwrap namespace alive — including the
    # runtime probe's WebDriver and its :1420 server, which then squatted
    # the port and poisoned the NEXT round (run 30). `timeout` fires a few
    # seconds before the Elixir deadline so the kill is the shell's, with a
    # SIGKILL backstop for anything ignoring SIGTERM.
    inner_deadline_s = max(div(timeout_ms, 1000) - 5, 5)
    guarded = "timeout -k 10 #{inner_deadline_s} sh -c #{shell_quote(command)}"

    {cmd, cmd_args} = GiTF.Sandbox.wrap_shell(guarded, cd: cwd)

    task =
      Task.async(fn ->
        System.cmd(cmd, cmd_args, cd: cwd, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, exit_code}} when exit_code in [126, 127] ->
        # Shell "not executable"/"not found" — a HOST provisioning gap,
        # not the ghost's code. Blaming the diff sent missions into
        # fail-loops over a missing npm.
        {:error, :tool_missing,
         "TOOL MISSING on host (exit #{exit_code}) — the validation command's toolchain " <>
           "is not installed; this is an infrastructure problem, not a code problem: " <>
           String.slice(output, 0, 300), exit_code}

      {:ok, {output, exit_code}} ->
        {:error, :failed, "Command failed (exit #{exit_code}): #{tail_slice(output, 900)}",
         exit_code}

      nil ->
        {:error, :timeout, "Validation command timed out after #{div(timeout_ms, 1000)}s", 124}
    end
  rescue
    e -> {:error, :crashed, "Validation command error: #{Exception.message(e)}", 1}
  end

  @doc """
  Runs a custom shell command in the shell worktree.

  Thin shape adapter over `run_validation/4` for callers that only care
  whether it passed.
  """
  @spec run_custom_validation(map(), String.t(), pos_integer() | nil) ::
          :ok | {:error, String.t()}
  def run_custom_validation(shell, command, timeout_ms \\ nil) do
    case run_validation(shell.worktree_path, command, nil, timeout_ms: timeout_ms) do
      {:ok, _output} -> :ok
      {:error, _kind, message, _exit_code} -> {:error, message}
    end
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
            {:error, reason} -> inconclusive("validator API call failed: #{inspect(reason)}")
          end
        else
          # CLI mode: spawn headless and collect
          case GiTF.Runtime.Models.spawn_headless(prompt, shell.worktree_path) do
            {:ok, port} ->
              collect_validation_result(port)

            {:error, reason} ->
              inconclusive("validator spawn failed: #{inspect(reason)}")
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

      {^port, {:exit_status, code}} ->
        inconclusive("validator process exited non-zero (#{code})")
    after
      timeout ->
        safe_close_port(port)
        inconclusive("validator timed out after #{timeout}ms")
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
        inconclusive("validator output had no parseable verdict")
    end
  end

  # A validation we could not complete must NOT be treated as a pass — that
  # would turn a broken validator into silently-disabled validation. Surface
  # it as an inconclusive error so the caller blocks/retries (fail-safe).
  defp inconclusive(reason) do
    Logger.warning("Validation inconclusive: #{reason}")
    {:error, :validation_inconclusive, %{reason: reason}}
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

  # Single-quote for `sh -c`, closing and reopening around embedded quotes.
  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  # Last `max` bytes of command output, valid UTF-8, with an ellipsis when
  # truncated — pipelines put their verdict at the end.
  defp tail_slice(output, max) do
    output = to_string(output)

    if String.length(output) > max do
      "…" <> String.slice(output, -max, max)
    else
      output
    end
  end
end
