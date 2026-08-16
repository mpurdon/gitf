defmodule GiTF.FlagsTest do
  use ExUnit.Case, async: false

  alias GiTF.Flags

  setup do
    on_exit(fn ->
      Application.delete_env(:gitf, :skills_enabled)
      Application.delete_env(:gitf, :lsp_validation_enabled)
    end)
  end

  test "applies whitelisted boolean flags to Application env" do
    applied =
      Flags.apply_from_config(%{
        features: %{skills_enabled: true, lsp_validation_enabled: false}
      })

    assert Enum.sort(applied) == [:lsp_validation_enabled, :skills_enabled]
    assert Application.get_env(:gitf, :skills_enabled) == true
    assert Application.get_env(:gitf, :lsp_validation_enabled) == false
  end

  test "ignores unknown flags and non-boolean values" do
    before = Application.get_env(:gitf, :skills_enabled)

    applied =
      Flags.apply_from_config(%{
        features: %{
          not_a_real_flag: true,
          skills_enabled: "yes"
        }
      })

    assert applied == []
    assert Application.get_env(:gitf, :not_a_real_flag) == nil
    # Non-boolean value must leave the flag exactly as it was.
    assert Application.get_env(:gitf, :skills_enabled) == before
  end

  test "a config with no [features] table applies nothing" do
    assert Flags.apply_from_config(%{}) == []
    assert Flags.apply_from_config(%{features: nil}) == []
  end

  test "flags absent from the table are left untouched" do
    Application.put_env(:gitf, :lsp_validation_enabled, true)
    Flags.apply_from_config(%{features: %{skills_enabled: true}})
    assert Application.get_env(:gitf, :lsp_validation_enabled) == true
  end
end
