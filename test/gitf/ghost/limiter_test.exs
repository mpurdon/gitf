defmodule GiTF.Ghost.LimiterTest do
  use ExUnit.Case, async: true

  alias GiTF.Ghost.Limiter

  describe "friction_instructions/1" do
    test "low risk returns empty string" do
      assert Limiter.friction_instructions(:low) == ""
    end

    test "medium risk mentions config files" do
      result = Limiter.friction_instructions(:medium)
      assert result =~ "config files"
      assert result =~ "explain your reasoning"
    end

    test "high risk requires stating changes and clarification link_msg" do
      result = Limiter.friction_instructions(:high)
      assert result =~ "Before any file write"
      assert result =~ "clarification_needed"
    end

    test "critical risk prohibits file writes" do
      result = Limiter.friction_instructions(:critical)
      assert result =~ "Do NOT write any files"
      assert result =~ "detailed plan"
      assert result =~ "reviewed by the queen"
    end

    test "nil risk level returns empty string" do
      assert Limiter.friction_instructions(nil) == ""
    end

    test "unknown atom returns empty string" do
      assert Limiter.friction_instructions(:unknown) == ""
    end
  end

  describe "requires_confirmation?/1" do
    test "low does not require confirmation" do
      refute Limiter.requires_confirmation?(:low)
    end

    test "medium does not require confirmation" do
      refute Limiter.requires_confirmation?(:medium)
    end

    test "high requires confirmation" do
      assert Limiter.requires_confirmation?(:high)
    end

    test "critical requires confirmation" do
      assert Limiter.requires_confirmation?(:critical)
    end

    test "nil does not require confirmation" do
      refute Limiter.requires_confirmation?(nil)
    end
  end
end
