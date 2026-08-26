defmodule GiTF.Infra.HostStats do
  @moduledoc """
  Host vitals: memory, CPU, uptime, network, and the BEAM's own footprint.

  Every question about "how is the box doing" has meant shelling in over
  SSM — which is unavailable exactly when it matters most (the
  2026-08-19 disk-full took SSM down with it). These are the numbers that
  actually predicted trouble: BEAM RSS against total memory (two OOM kills
  when a 1GB BEAM met a parallel cargo build), swap in use (the first sign
  of pressure), and load against core count.

  Everything is read from /proc and the BEAM itself — no external
  binaries, so the report works when the host is too sick to fork.
  """

  @doc "Memory, CPU, uptime, network, BEAM footprint, and a headroom verdict."
  @spec report() :: map()
  def report do
    mem = memory()

    %{
      memory: mem,
      cpu: cpu(),
      uptime: uptime(),
      beam: beam(),
      network: network(),
      headroom: headroom(mem)
    }
  end

  # -- memory ------------------------------------------------------------------

  defp memory do
    info = meminfo()
    total = info["MemTotal"] || 0
    available = info["MemAvailable"] || 0
    swap_total = info["SwapTotal"] || 0
    swap_free = info["SwapFree"] || 0

    %{
      total_mb: kb_mb(total),
      available_mb: kb_mb(available),
      used_mb: kb_mb(total - available),
      swap_total_mb: kb_mb(swap_total),
      swap_used_mb: kb_mb(swap_total - swap_free),
      used_pct: pct(total - available, total)
    }
  end

  defp meminfo do
    case File.read("/proc/meminfo") do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ~r/:\s+/, parts: 2) do
            [key, value] ->
              case value |> String.replace(" kB", "") |> Integer.parse() do
                {kb, _} -> Map.put(acc, key, kb)
                :error -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  # -- cpu / uptime ------------------------------------------------------------

  defp cpu do
    cores = System.schedulers_online()

    load =
      case File.read("/proc/loadavg") do
        {:ok, body} ->
          case String.split(body) do
            [one, five, fifteen | _] ->
              %{one: to_float(one), five: to_float(five), fifteen: to_float(fifteen)}

            _ ->
              %{}
          end

        _ ->
          %{}
      end

    # Load per core is the honest saturation signal on a 2-core box: a raw
    # load of 2.0 means "fully busy" here and "idle" on a 16-core host.
    per_core = if cores > 0 and is_number(load[:one]), do: Float.round(load.one / cores, 2)

    Map.merge(load, %{cores: cores, load_per_core: per_core})
  end

  defp uptime do
    case File.read("/proc/uptime") do
      {:ok, body} ->
        case body |> String.split() |> List.first() |> to_float() do
          seconds when is_float(seconds) ->
            %{seconds: round(seconds), hours: Float.round(seconds / 3600, 1)}

          _ ->
            %{seconds: nil, hours: nil}
        end

      _ ->
        %{seconds: nil, hours: nil}
    end
  end

  # -- BEAM --------------------------------------------------------------------

  defp beam do
    total = :erlang.memory(:total)

    %{
      total_mb: bytes_mb(total),
      processes_mb: bytes_mb(:erlang.memory(:processes)),
      ets_mb: bytes_mb(:erlang.memory(:ets)),
      binary_mb: bytes_mb(:erlang.memory(:binary)),
      process_count: :erlang.system_info(:process_count)
    }
  end

  # -- network -----------------------------------------------------------------

  defp network do
    case File.ls("/sys/class/net") do
      {:ok, ifaces} ->
        for iface <- Enum.sort(ifaces), iface != "lo" do
          %{
            name: iface,
            driver: read_link_basename("/sys/class/net/#{iface}/device/driver"),
            mtu: read_int("/sys/class/net/#{iface}/mtu"),
            state: read_trim("/sys/class/net/#{iface}/operstate"),
            rx_errors: read_int("/sys/class/net/#{iface}/statistics/rx_errors"),
            tx_errors: read_int("/sys/class/net/#{iface}/statistics/tx_errors")
          }
        end

      _ ->
        []
    end
  end

  # -- verdict -----------------------------------------------------------------

  # The thresholds that would have predicted the real incidents: swap in
  # use at all means the box is already borrowing, and under ~700MB
  # available a concurrent cargo build is what killed the BEAM twice.
  @doc false
  # Public for tests: the thresholds are the point of this module.
  def headroom_for(mem), do: headroom(mem)

  defp headroom(%{available_mb: avail, swap_used_mb: swap}) when is_number(avail) do
    cond do
      avail < 400 ->
        %{status: "critical", note: "under 400MB available — a build will OOM the BEAM"}

      swap > 200 ->
        %{status: "degraded", note: "swapping #{swap}MB — memory pressure is real"}

      avail < 700 ->
        %{status: "tight", note: "under 700MB available — avoid concurrent builds"}

      true ->
        %{status: "ok", note: "#{avail}MB available"}
    end
  end

  defp headroom(_), do: %{status: "unknown", note: "could not read /proc/meminfo"}

  # -- helpers -----------------------------------------------------------------

  defp kb_mb(kb) when is_integer(kb), do: div(kb, 1024)
  defp kb_mb(_), do: nil

  defp bytes_mb(b) when is_integer(b), do: div(b, 1024 * 1024)
  defp bytes_mb(_), do: nil

  defp pct(_, 0), do: nil

  defp pct(part, whole) when is_integer(part) and is_integer(whole),
    do: Float.round(part / whole * 100, 1)

  defp pct(_, _), do: nil

  defp to_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp read_trim(path) do
    case File.read(path) do
      {:ok, body} -> String.trim(body)
      _ -> nil
    end
  end

  defp read_int(path) do
    case read_trim(path) do
      nil ->
        nil

      str ->
        case Integer.parse(str) do
          {n, _} -> n
          :error -> nil
        end
    end
  end

  defp read_link_basename(path) do
    case File.read_link(path) do
      {:ok, target} -> Path.basename(target)
      _ -> nil
    end
  end
end
