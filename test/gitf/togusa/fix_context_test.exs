defmodule GiTF.Togusa.FixContextTest do
  use ExUnit.Case, async: true

  alias GiTF.Togusa.FixContext

  describe "record_attempt + format_for_prompt with map-valued failures" do
    test "renders requirements_met (list of maps) without String.Chars crash" do
      validation = %{
        "summary" => "validation failed",
        "requirements_met" => [
          %{"req_id" => "FR-1", "met" => false, "evidence" => "label still wrong"},
          %{"req_id" => "FR-2", "met" => false, "evidence" => "function not renamed"}
        ],
        "gaps" => ["new collapseAll function not implemented"]
      }

      ctx = FixContext.new("op-orig")
      ctx = FixContext.record_attempt(ctx, :goal_fulfillment, "op-orig", validation, "feedback")

      # Previously this raised: protocol String.Chars not implemented for Map
      prompt = FixContext.format_for_prompt(ctx)

      assert is_binary(prompt)
      assert String.contains?(prompt, "FR-1")
      assert String.contains?(prompt, "label still wrong")
      assert String.contains?(prompt, "collapseAll")
    end

    test "handles deeply nested maps" do
      validation = %{
        "errors" => [
          %{"path" => "a.b.c", "details" => %{"line" => 42, "col" => 7}}
        ]
      }

      ctx = FixContext.new("op-orig")
      ctx = FixContext.record_attempt(ctx, :goal_fulfillment, "op-orig", validation, "")

      prompt = FixContext.format_for_prompt(ctx)
      assert is_binary(prompt)
      assert String.contains?(prompt, "a.b.c")
    end

    test "handles plain string-list failures (regression)" do
      validation = %{"errors" => ["err1", "err2"]}

      ctx = FixContext.new("op-orig")
      ctx = FixContext.record_attempt(ctx, :goal_fulfillment, "op-orig", validation, "")

      prompt = FixContext.format_for_prompt(ctx)
      assert String.contains?(prompt, "err1, err2")
    end
  end
end
