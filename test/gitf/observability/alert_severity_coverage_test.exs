defmodule GiTF.Observability.AlertSeverityCoverageTest do
  use ExUnit.Case, async: true

  alias GiTF.Observability.Alerts

  # Every alert type dispatched anywhere in lib/ must have an explicit
  # severity mapping. The default for unknown types is :high (fail-loud),
  # but relying on it means the author never decided how urgent the alert
  # is — historically that default was :low and silently suppressed
  # mission-failure and budget alerts below the webhook floor.
  test "every dispatch_webhook literal in lib/ has an explicit severity" do
    dispatched_types =
      Path.wildcard(Path.join(File.cwd!(), "lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/dispatch_webhook\(\s*:(\w+)/, File.read!(file))
        |> Enum.map(fn [_, type] -> String.to_atom(type) end)
      end)
      |> Enum.uniq()

    assert dispatched_types != [], "expected to find dispatch_webhook call sites in lib/"

    unmapped =
      Enum.reject(dispatched_types, fn type ->
        # An explicit entry differs from the fail-loud default only when the
        # map actually contains the key.
        Alerts.severity(type) != :high or explicit?(type)
      end)

    assert unmapped == [],
           "alert types dispatched without a @severity_map entry: #{inspect(unmapped)}"
  end

  defp explicit?(type) do
    # severity/1 hides map membership; probe via the module attribute's
    # published behavior — an unmapped type returns the :high default, so
    # cross-check against the source to distinguish explicit :high entries.
    source = File.read!(Path.join(File.cwd!(), "lib/gitf/observability/alerts.ex"))
    String.contains?(source, "#{type}:")
  end

  test "unknown alert types default to :high, not :low" do
    assert Alerts.severity(:definitely_not_a_real_alert_type) == :high
  end
end
