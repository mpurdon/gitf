defmodule GiTF.GitHub.CLIFieldsTest do
  @moduledoc """
  `gh pr view --json` rejects the whole request if any field name is unknown,
  so the field list is a compatibility surface with an external binary. When
  gh dropped `merged`, every outcome poll failed — classified transient,
  retried on backoff, and invisible because the output was discarded. These
  guard the shape of what we ask for and how merged-ness is derived.
  """
  use ExUnit.Case, async: true

  @source File.read!("lib/gitf/github/cli.ex")

  test "does not ask gh for the removed `merged` field" do
    fields =
      Regex.run(~r/fields = "([^"]+)"/, @source)
      |> Enum.at(1)
      |> String.split(",")

    refute "merged" in fields,
           "gh removed the `merged` JSON field; requesting it fails the entire call"

    # The fields we do rely on downstream.
    for required <- ~w(state mergedAt closedAt reviews) do
      assert required in fields
    end
  end

  test "merged-ness is derived from mergedAt, not a boolean field" do
    assert @source =~ ~r/merged:\s*not is_nil\(Map\.get\(data, "mergedAt"\)\)/
  end

  test "a failing gh call logs what went wrong" do
    # The bug survived because run_gh returned :transient and threw the
    # output away, so an impossible request looked like flaky networking.
    assert @source =~ ~r/Logger\.warning\(/
  end
end
