defmodule GiTF.CLI.SectorTimeoutOptionTest do
  @moduledoc """
  The CLI dispatch path halts the VM on a bad value, so it can't be driven from
  ExUnit. Guard the surface at the source instead: `validation_timeout_ms` was
  read by `GiTF.Validator` but writable from nowhere, and dropping it back out
  of either whitelist would silently restore the 120s-for-everything behaviour
  that reported every cora op as a timeout.
  """
  use ExUnit.Case, async: true

  @cli File.read!("lib/gitf/cli.ex")

  test "sector add and sector set both declare --validation-timeout-ms" do
    assert length(String.split(@cli, "long: \"--validation-timeout-ms\"")) - 1 == 2
  end

  test "the sector set update whitelist includes the field" do
    assert @cli =~ ~r/\[:validation_command,\s*:validation_timeout_ms,\s*:sync_strategy\]/
  end

  test "remote sector add forwards the field to the daemon" do
    assert @cli =~ ~r/:validation_command,\s*:validation_timeout_ms,\s*:github_owner/
  end

  test "bounds come from the single owner, not a local guard" do
    # The CLI, HTTP API and MCP tool each grew their own bounds check and
    # drifted (two of three accepted an 11-day deadline). The invariant now
    # is delegation: this surface parses strings, Validator judges numbers.
    assert @cli =~ "defp parse_validation_timeout!"
    assert @cli =~ "GiTF.Validator.validate_timeout_override("
  end
end
