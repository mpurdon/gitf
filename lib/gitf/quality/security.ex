defmodule GiTF.Quality.Security do
  @moduledoc """
  Security scanning for ghost worktrees.
  """

  require Logger

  @doc """
  Run security scans on a shell.
  Returns {:ok, results} with security score and findings.

  `available: false` means the dependency audit could not actually run
  (tool missing, crashed, or timed out). Empty findings from a scanner that
  never ran must NOT read as a clean bill: `[]` scores 100, so a missing
  `npm` used to make every op's security gate green forever. Callers treat
  unavailable as inconclusive, never as clean.
  """
  def scan(shell_path, language) do
    {dep_findings, available} =
      case check_dependencies(shell_path, language) do
        {:unavailable, reason} ->
          Logger.warning("Dependency audit unavailable (#{reason}) in #{shell_path}")
          {[], false}

        findings when is_list(findings) ->
          {findings, true}
      end

    findings =
      [
        check_secrets(shell_path),
        dep_findings,
        check_vulnerabilities(shell_path, language)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    score = calculate_security_score(findings)

    {:ok,
     %{
       findings: findings,
       score: score,
       tool: "section-security",
       available: available
     }}
  end

  # Secret detection
  defp check_secrets(path) do
    patterns = [
      {~r/(?i)(api[_-]?key|apikey)\s*[:=]\s*['"][^'"]{20,}['"]/, "API Key"},
      {~r/(?i)(secret[_-]?key|secretkey)\s*[:=]\s*['"][^'"]{20,}['"]/, "Secret Key"},
      {~r/(?i)(password|passwd|pwd)\s*[:=]\s*['"][^'"]{8,}['"]/, "Password"},
      {~r/(?i)(token|auth[_-]?token)\s*[:=]\s*['"][^'"]{20,}['"]/, "Auth Token"},
      {~r/(?i)(private[_-]?key|privatekey)\s*[:=]\s*['"]-----BEGIN/, "Private Key"},
      {~r/(?i)aws[_-]?(access[_-]?key[_-]?id|secret[_-]?access[_-]?key)/, "AWS Credentials"}
    ]

    find_in_files(path, patterns, "secret")
  end

  # Common vulnerability patterns
  defp check_vulnerabilities(path, language) do
    patterns =
      case language do
        :elixir -> elixir_vuln_patterns()
        :javascript -> js_vuln_patterns()
        :typescript -> js_vuln_patterns()
        :python -> python_vuln_patterns()
        _ -> []
      end

    find_in_files(path, patterns, "vulnerability")
  end

  # Dependency vulnerability scanning
  defp check_dependencies(path, language) do
    case language do
      # mix deps.audit exits 0 on a clean tree with prose that the line
      # parser must not see — short-circuit exit 0 to no-findings.
      :elixir ->
        run_audit(path, "mix", ["deps.audit"], fn
          {_out, 0} -> []
          {out, _} -> parse_mix_audit(out)
        end)

      :javascript ->
        run_audit(path, "npm", ["audit", "--json"], fn {out, _} -> parse_npm_audit(out) end)

      :typescript ->
        run_audit(path, "npm", ["audit", "--json"], fn {out, _} -> parse_npm_audit(out) end)

      :rust ->
        run_audit(path, "cargo", ["audit", "--json"], fn {out, _} -> parse_cargo_audit(out) end)

      :python ->
        run_audit(path, "pip-audit", ["--format", "json"], fn {out, _} -> parse_pip_audit(out) end)

      _ ->
        []
    end
  end

  @audit_timeout_ms 60_000

  # One skeleton for every dependency auditor. The tool runs inside a
  # Task because System.cmd raises :enoent INSIDE the task and a
  # caller-side rescue cannot catch a linked task's exit — it crashed the
  # whole quality pass, misattributed to gitf. Missing/crashed/timed-out
  # tools are UNAVAILABLE, never "no findings": [] scores 100, and a
  # verdict must not depend on which tools the host happens to have.
  defp run_audit(path, exe, args, result_fn) do
    task =
      Task.async(fn ->
        if System.find_executable(exe) do
          try do
            System.cmd(exe, args, cd: path, stderr_to_stdout: true)
          rescue
            _ -> :tool_error
          end
        else
          :tool_missing
        end
      end)

    case Task.yield(task, @audit_timeout_ms) || Task.shutdown(task, 5_000) do
      {:ok, {output, code}} when is_binary(output) -> result_fn.({output, code})
      {:ok, reason} when is_atom(reason) -> {:unavailable, reason}
      nil -> {:unavailable, :timeout}
    end
  rescue
    _ -> {:unavailable, :scanner_crashed}
  end

  defp parse_mix_audit(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "vulnerability"))
    |> Enum.map(fn line ->
      %{
        severity: 3,
        type: "dependency",
        message: String.trim(line),
        file: "mix.lock"
      }
    end)
  end

  defp parse_npm_audit(output) do
    case Jason.decode(output) do
      {:ok, %{"vulnerabilities" => vulns}} when is_map(vulns) ->
        vulns
        |> Enum.flat_map(fn {_pkg, data} ->
          case data do
            %{"via" => via} when is_list(via) ->
              Enum.map(via, fn v ->
                %{
                  severity: severity_from_npm(v["severity"]),
                  type: "dependency",
                  message: "#{v["title"]} in #{v["name"]}",
                  file: "package.json"
                }
              end)

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp parse_cargo_audit(output) do
    case Jason.decode(output) do
      {:ok, %{"vulnerabilities" => %{"list" => vulns}}} when is_list(vulns) ->
        Enum.map(vulns, fn v ->
          %{
            severity: 3,
            type: "dependency",
            message: "#{v["advisory"]["title"]} in #{v["package"]["name"]}",
            file: "Cargo.lock"
          }
        end)

      _ ->
        []
    end
  end

  defp parse_pip_audit(output) do
    case Jason.decode(output) do
      {:ok, %{"vulnerabilities" => vulns}} when is_list(vulns) ->
        Enum.map(vulns, fn v ->
          %{
            severity: 3,
            type: "dependency",
            message: "#{v["id"]} in #{v["name"]}",
            file: "requirements.txt"
          }
        end)

      _ ->
        []
    end
  end

  defp severity_from_npm("critical"), do: 3
  defp severity_from_npm("high"), do: 3
  defp severity_from_npm("moderate"), do: 2
  defp severity_from_npm(_), do: 1

  defp elixir_vuln_patterns do
    [
      {~r/String\.to_atom\(/, "Unsafe atom creation (DoS risk)"},
      {~r/Code\.eval_string\(/, "Code injection risk"},
      {~r/:os\.cmd\(/, "OS command injection risk"}
    ]
  end

  defp js_vuln_patterns do
    [
      {~r/eval\(/, "Code injection via eval()"},
      {~r/innerHTML\s*=/, "XSS risk via innerHTML"},
      {~r/dangerouslySetInnerHTML/, "XSS risk in React"},
      {~r/document\.write\(/, "XSS risk via document.write"}
    ]
  end

  defp python_vuln_patterns do
    [
      {~r/eval\(/, "Code injection via eval()"},
      {~r/exec\(/, "Code injection via exec()"},
      {~r/pickle\.loads?\(/, "Deserialization vulnerability"},
      {~r/os\.system\(/, "OS command injection risk"}
    ]
  end

  # Vendored/generated trees are not the mission's code. Scanning them made the
  # verdict depend on install state: a worktree audited before `npm ci` passed,
  # then re-audited after validation installed node_modules the same wildcard's
  # first 500 files were vendor JS, vuln patterns lit up on minified dependency
  # code, and the score collapsed to 0 (msn-aa92dd was auto-rejected on exactly
  # this flap). Scan only the project's own sources.
  @excluded_dirs ~w(node_modules deps _build target dist build vendor .git)

  defp find_in_files(path, patterns, type) do
    Path.wildcard(Path.join(path, "**/*.{ex,exs,js,jsx,ts,tsx,py,rs}"))
    |> Enum.reject(&excluded_path?(&1, path))
    # Limit files scanned
    |> Enum.take(500)
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, content} ->
          patterns
          |> Enum.flat_map(fn {pattern, desc} ->
            content
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> Regex.match?(pattern, line) end)
            |> Enum.map(fn {_line, line_no} ->
              %{
                severity: 2,
                type: type,
                message: desc,
                file: Path.relative_to(file, path),
                line: line_no
              }
            end)
          end)

        _ ->
          []
      end
    end)
  end

  defp excluded_path?(file, root) do
    file
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @excluded_dirs))
  end

  defp calculate_security_score(findings) do
    penalty =
      Enum.reduce(findings, 0, fn finding, acc ->
        case finding.severity do
          # Critical: -20 points
          3 -> acc + 20
          # Warning: -10 points
          2 -> acc + 10
          # Info: -5 points
          _ -> acc + 5
        end
      end)

    max(0, 100 - penalty)
  end
end
