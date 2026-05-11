defmodule GiTF.Visual.Capture do
  @moduledoc """
  Headless-browser screenshot capture for visual validation.

  Wraps Playwright's bundled CLI (`npx playwright screenshot URL FILE`).
  The Factory uses this to verify frontend missions actually render
  before a PR is opened — pure syntax+test signal misses broken layouts,
  blank pages, and missing interactivity that a render check catches
  cheaply.

  ## Setup

  Requires Playwright installed in a node-accessible location:

      npm install -g playwright
      npx playwright install chromium

  Without this, `available?/0` returns false and `screenshot/3` returns
  `{:error, :driver_unavailable}`. Feature-gated by
  `:visual_capture_enabled` so absence doesn't break startup.

  ## Future

  M2 adds a `visual_validation` phase that takes before/after shots of
  changed routes and posts them as PR comments. M3 adds visual-diff
  scoring. For now this module is just the capture primitive.
  """

  require Logger

  @default_timeout_ms 30_000

  @type opts :: [
          full_page: boolean(),
          viewport: {pos_integer(), pos_integer()},
          wait_ms: non_neg_integer(),
          timeout_ms: pos_integer()
        ]

  @doc """
  Takes a screenshot of `url` and writes it to `output_path` (PNG).

  Options:
    * `:full_page` — capture the full scrollable page (default true)
    * `:viewport` — `{w, h}` viewport size (default `{1280, 720}`)
    * `:wait_ms` — delay after navigation before snapping (default 0)
    * `:timeout_ms` — overall command timeout (default 30s)
  """
  @spec screenshot(String.t(), Path.t(), opts()) :: {:ok, Path.t()} | {:error, term()}
  def screenshot(url, output_path, opts \\ []) when is_binary(url) and is_binary(output_path) do
    cond do
      not enabled?() -> {:error, :disabled}
      not available?() -> {:error, :driver_unavailable}
      not allowed_url?(url) -> {:error, {:url_not_allowed, url}}
      true ->
        case allowed_output_path(output_path) do
          {:ok, expanded} -> do_screenshot(url, expanded, opts)
          {:error, _} = err -> err
        end
    end
  end

  # Reject anything that isn't http(s); that closes off file://, ftp://,
  # and the kind of URLs an attacker would supply for SSRF or local file
  # exfiltration through the headless browser.
  defp allowed_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        not internal_host?(host)

      _ ->
        false
    end
  end

  # IMDS, loopback, and RFC1918 ranges are common SSRF targets. Operators
  # who need them can flip :visual_capture_allow_internal.
  defp internal_host?(host) do
    if Application.get_env(:gitf, :visual_capture_allow_internal, false) do
      false
    else
      cond do
        host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "169.254.169.254"] -> true
        String.starts_with?(host, "10.") -> true
        String.starts_with?(host, "192.168.") -> true
        Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./, host) -> true
        String.ends_with?(host, ".internal") -> true
        true -> false
      end
    end
  end

  # Output path must land in a configured screenshots directory so a
  # caller can't drop files into ~/.ssh, LaunchAgents, or arbitrary
  # workspace paths. Default: <gitf_dir>/.gitf/screenshots/.
  defp allowed_output_path(path) do
    expanded = Path.expand(path)

    case screenshots_root() do
      {:ok, root} ->
        if String.starts_with?(expanded, root <> "/") and
             String.ends_with?(expanded, ".png") do
          {:ok, expanded}
        else
          {:error, {:output_path_not_allowed, path}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp screenshots_root do
    case Application.get_env(:gitf, :visual_screenshots_root) do
      path when is_binary(path) ->
        {:ok, Path.expand(path)}

      _ ->
        case GiTF.gitf_dir() do
          {:ok, gitf_root} ->
            {:ok, Path.expand(Path.join([gitf_root, ".gitf", "screenshots"]))}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  True when the configured driver (Playwright by default) is on the
  PATH. Cached per-process to avoid reprobing on every call.
  """
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get({__MODULE__, :available}, :unknown) do
      :unknown ->
        result = probe_driver()
        :persistent_term.put({__MODULE__, :available}, result)
        result

      cached ->
        cached
    end
  end

  @doc "True when `:visual_capture_enabled` is set."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :visual_capture_enabled, false) == true

  @doc """
  Forces a re-probe of the driver. Useful in tests or after installing
  Playwright on a running node.
  """
  @spec invalidate_driver_cache() :: :ok
  def invalidate_driver_cache do
    :persistent_term.erase({__MODULE__, :available})
    :ok
  end

  # -- Internal --------------------------------------------------------------

  defp do_screenshot(url, output_path, opts) do
    File.mkdir_p!(Path.dirname(output_path))

    args = build_args(url, output_path, opts)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case run_cmd(npx_path(), args, timeout) do
      {:ok, _output} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, :no_output}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_args(url, output_path, opts) do
    base = ["playwright", "screenshot", url, output_path]

    base =
      case Keyword.get(opts, :viewport) do
        {w, h} when is_integer(w) and is_integer(h) ->
          base ++ ["--viewport-size=#{w},#{h}"]

        _ ->
          base
      end

    base =
      case Keyword.get(opts, :wait_ms) do
        ms when is_integer(ms) and ms > 0 -> base ++ ["--wait-for-timeout=#{ms}"]
        _ -> base
      end

    if Keyword.get(opts, :full_page, true) do
      base ++ ["--full-page"]
    else
      base
    end
  end

  defp run_cmd(cmd, args, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd(cmd, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit, code, output}}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exited, reason}}
    end
  end

  defp probe_driver do
    case run_cmd(npx_path(), ["playwright", "--version"], 5_000) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.debug("Visual.Capture driver probe failed: #{inspect(reason)}")
        false
    end
  rescue
    _ -> false
  end

  defp npx_path do
    System.find_executable("npx") || "npx"
  end
end
