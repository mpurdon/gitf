defmodule GiTF.Sync.ResolverValidationTest do
  @moduledoc """
  Guards the merge-resolution validation gate.

  Tier 2 (AI resolve) is the only tier that validates before committing a
  merge, so what this gate does when it is unsure decides whether
  model-authored conflict resolutions reach a branch unchecked.
  """

  use ExUnit.Case, async: true

  # Code only. These modules explain in prose what they no longer do, and a
  # guard that reads its own documentation as a violation gets deleted.
  @resolver "lib/gitf/sync/resolver.ex"
            |> File.read!()
            |> String.split("\n")
            |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
            |> Enum.join("\n")

  describe "the validation gate" do
    test "fails closed" do
      # Was `rescue _ -> :ok`: any unexpected exception — a nil sector.path
      # raising KeyError, an Archive miss, a sandbox policy refusal — returned
      # :ok and the merge was committed as though validation had passed.
      refute @resolver =~ ~r/rescue\s*\n\s*_\s*->\s*:ok/,
             "validate_resolution must not rescue to :ok — that commits a merge on an error"
    end

    test "runs the command through the shared runner, not its own shell" do
      refute @resolver =~ ~s|System.cmd("sh"|,
             "the resolver must not shell out directly; GiTF.Validator.run_validation/4 is " <>
               "the only path that sandboxes the command and gives it an OS-level deadline"

      assert @resolver =~ "GiTF.Validator.run_validation("
    end

    test "does not reject commands by substring blocklist" do
      # The blocklist matched substrings, so a sector whose validation command
      # contained `rm -rf node_modules` — cora's does — lost the AI tier
      # entirely and was told only "contains blocked operation". `npm run
      # format` and `concurrently` tripped it the same way. It also guarded
      # the wrong thing: validation_command comes from onboarding detection or
      # an operator, never from a model, and Validator/Audit/Debrief run that
      # same field with no blocklist at all.
      refute @resolver =~ "@validation_blocklist",
             "the substring blocklist blocked real commands and confined nothing; " <>
               "the sandbox is the boundary"
    end
  end

  describe "cora's validation command" do
    # The concrete case that motivated the change.
    @cora "npm ci && test -f node_modules/typescript/lib/lib.es5.d.ts || " <>
            "(rm -rf node_modules && npm cache verify && npm ci) ; npm run typecheck && " <>
            "bash /var/lib/gitf/probes/cora-smoke.sh"

    test "would have been rejected by the old blocklist" do
      old_blocklist = ~w(rm sudo chmod chown curl wget ssh scp rsync nc ncat mkfifo)
      lower = String.downcase(@cora)

      assert Enum.any?(old_blocklist, &String.contains?(lower, &1)),
             "if this stops being true the regression it guards is gone"
    end
  end
end
