defmodule GiTF.Quality.Security do
  @moduledoc """
  Security scanning for ghost worktrees.
  """

  @doc """
  Run security scans on a shell.
  Returns {:ok, results} with security score and findings.
  """
  def scan(shell_path, language) do
    findings = [
      check_secrets(shell_path),
      check_dependencies(shell_path, language),
      check_vulnerabilities(shell_path, language)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)

    score = calculate_security_score(findings)

    {:ok, %{
      findings: findings,
      score: score,
      tool: "section-security"
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

  # Dependency vulnerability scanning
  defp check_dependencies(path, language) do
    case language do
      :elixir -> check_mix_audit(path)
      :javascript -> check_npm_audit(path)
      :typescript -> check_npm_audit(path)
      :rust -> check_cargo_audit(path)
      :python -> check_pip_audit(path)
      _ -> []
    end
  end

  # Common vulnerability patterns
  defp check_vulnerabilities(path, language) do
    patterns = case language do
      :elixir -> elixir_vuln_patterns()
      :javascript -> js_vuln_patterns()
      :typescript -> js_vuln_patterns()
      :python -> python_vuln_patterns()
      _ -> []
    end

    find_in_files(path, patterns, "vulnerability")
  end

  @audit_timeout_ms 60_000

  defp check_mix_audit(path) do
    task = Task.async(fn ->
      System.cmd("mix", ["deps.audit"], cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @audit_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {_output, 0}} -> []
      {:ok, {output, _}} -> parse_mix_audit(output)
      nil -> []
    end
  rescue
    _ -> []
  end

  defp check_npm_audit(path) do
    task = Task.async(fn ->
      System.cmd("npm", ["audit", "--json"], cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @audit_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_npm_audit(output)
      nil -> []
    end
  rescue
    _ -> []
  end

  defp check_cargo_audit(path) do
    task = Task.async(fn ->
      System.cmd("cargo", ["audit", "--json"], cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @audit_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_cargo_audit(output)
      nil -> []
    end
  rescue
    _ -> []
  end

  defp check_pip_audit(path) do
    task = Task.async(fn ->
      System.cmd("pip-audit", ["--format", "json"], cd: path, stderr_to_stdout: true)
    end)

    case Task.yield(task, @audit_timeout_ms) || Task.exfil(task, 5_000) do
      {:ok, {output, _}} -> parse_pip_audit(output)
      nil -> []
    end
  rescue
    _ -> []
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
            _ -> []
          end
        end)
      _ -> []
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
      _ -> []
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
      _ -> []
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

  defp find_in_files(path, patterns, type) do
    Path.wildcard(Path.join(path, "**/*.{ex,exs,js,jsx,ts,tsx,py,rs}"))
    |> Enum.take(500)  # Limit files scanned
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
        _ -> []
      end
    end)
  end

  defp calculate_security_score(findings) do
    penalty = Enum.reduce(findings, 0, fn finding, acc ->
      case finding.severity do
        3 -> acc + 20  # Critical: -20 points
        2 -> acc + 10  # Warning: -10 points
        _ -> acc + 5   # Info: -5 points
      end
    end)

    max(0, 100 - penalty)
  end
end
