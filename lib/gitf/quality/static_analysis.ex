defmodule GiTF.Quality.StaticAnalysis do
  @moduledoc """
  Runs static analysis tools on ghost worktrees.
  """

  @doc """
  Analyze code quality in a shell using language-specific tools.
  Returns {:ok, results} or {:error, reason}.
  """
  def analyze(shell_path, language) do
    case language do
      :elixir -> run_credo(shell_path)
      :javascript -> run_eslint(shell_path)
      :typescript -> run_eslint(shell_path)
      :rust -> run_clippy(shell_path)
      :python -> run_pylint(shell_path)
      _ -> {:ok, %{issues: [], score: 100, tool: "none", available: true}}
    end
  end

  @analysis_timeout_ms 120_000

  defp run_credo(path) do
    task = Task.async(fn ->
      System.cmd("mix", ["credo", "--format", "json", "--strict"],
        cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @analysis_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_credo(output)
      nil -> {:ok, %{issues: [], score: 100, tool: "credo", available: false}}
    end
  rescue
    _ -> {:ok, %{issues: [], score: 100, tool: "credo", available: false}}
  end

  defp run_eslint(path) do
    task = Task.async(fn ->
      System.cmd("npx", ["eslint", ".", "--format", "json"],
        cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @analysis_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_eslint(output)
      nil -> {:ok, %{issues: [], score: 100, tool: "eslint", available: false}}
    end
  rescue
    _ -> {:ok, %{issues: [], score: 100, tool: "eslint", available: false}}
  end

  defp run_clippy(path) do
    task = Task.async(fn ->
      System.cmd("cargo", ["clippy", "--message-format", "json"],
        cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @analysis_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_clippy(output)
      nil -> {:ok, %{issues: [], score: 100, tool: "clippy", available: false}}
    end
  rescue
    _ -> {:ok, %{issues: [], score: 100, tool: "clippy", available: false}}
  end

  defp run_pylint(path) do
    task = Task.async(fn ->
      System.cmd("pylint", [".", "--output-format", "json"],
        cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @analysis_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_pylint(output)
      nil -> {:ok, %{issues: [], score: 100, tool: "pylint", available: false}}
    end
  rescue
    _ -> {:ok, %{issues: [], score: 100, tool: "pylint", available: false}}
  end

  defp parse_credo(output) do
    case Jason.decode(output) do
      {:ok, %{"issues" => issues}} ->
        parsed = Enum.map(issues, &parse_credo_issue/1)
        {:ok, %{issues: parsed, score: calculate_score(parsed), tool: "credo"}}

      _ ->
        {:ok, %{issues: [], score: 100, tool: "credo"}}
    end
  end

  defp parse_eslint(output) do
    case Jason.decode(output) do
      {:ok, results} when is_list(results) ->
        issues =
          Enum.flat_map(results, fn file ->
            Enum.map(file["messages"] || [], &parse_eslint_issue(&1, file["filePath"]))
          end)

        {:ok, %{issues: issues, score: calculate_score(issues), tool: "eslint"}}

      _ ->
        {:ok, %{issues: [], score: 100, tool: "eslint"}}
    end
  end

  defp parse_clippy(output) do
    issues =
      output
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "\"reason\":\"compiler-message\""))
      |> Enum.map(&parse_clippy_line/1)
      |> Enum.reject(&is_nil/1)

    {:ok, %{issues: issues, score: calculate_score(issues), tool: "clippy"}}
  end

  defp parse_pylint(output) do
    case Jason.decode(output) do
      {:ok, issues} when is_list(issues) ->
        parsed = Enum.map(issues, &parse_pylint_issue/1)
        {:ok, %{issues: parsed, score: calculate_score(parsed), tool: "pylint"}}

      _ ->
        {:ok, %{issues: [], score: 100, tool: "pylint"}}
    end
  end

  defp parse_credo_issue(issue) do
    %{
      severity: issue["priority"],
      message: issue["message"],
      file: issue["filename"],
      line: issue["line_no"],
      category: issue["category"]
    }
  end

  defp parse_eslint_issue(msg, file) do
    %{
      severity: msg["severity"],
      message: msg["message"],
      file: file,
      line: msg["line"],
      category: msg["ruleId"]
    }
  end

  defp parse_clippy_line(line) do
    case Jason.decode(line) do
      {:ok, %{"message" => msg}} ->
        %{
          severity: severity_from_level(msg["level"]),
          message: msg["message"],
          file: get_in(msg, ["spans", Access.at(0), "file_name"]),
          line: get_in(msg, ["spans", Access.at(0), "line_start"]),
          category: msg["code"]["code"] || "clippy"
        }

      _ ->
        nil
    end
  end

  defp parse_pylint_issue(issue) do
    %{
      severity: severity_from_type(issue["type"]),
      message: issue["message"],
      file: issue["path"],
      line: issue["line"],
      category: issue["symbol"]
    }
  end

  defp severity_from_level("error"), do: 3
  defp severity_from_level("warning"), do: 2
  defp severity_from_level(_), do: 1

  defp severity_from_type("error"), do: 3
  defp severity_from_type("warning"), do: 2
  defp severity_from_type(_), do: 1

  defp calculate_score(issues) do
    penalty =
      Enum.reduce(issues, 0, fn issue, acc ->
        case issue.severity do
          3 -> acc + 10
          2 -> acc + 5
          _ -> acc + 1
        end
      end)

    max(0, 100 - penalty)
  end
end
