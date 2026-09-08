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

    test "records a digest of a validation, never its raw_output or met entries — msn-ac0539's 77KB fix prompt" do
      validation = %{
        "raw_output" => String.duplicate(~s({"type":"assistant","message":{}}\n), 2000),
        "parse_failed" => true,
        "parse_error" => ":parse_failed",
        "requires_approval" => true,
        "overall_verdict" => "fail",
        "summary" => "one gap left",
        "requirements_met" => [
          %{
            "req_id" => "FR-1",
            "met" => true,
            "evidence" => "accepted in an earlier validation round"
          },
          %{"req_id" => "FR-5", "met" => false, "evidence" => "groupWeight still Math.min"}
        ],
        "gaps" => ["FR-5 unmet"]
      }

      ctx = FixContext.new("op-orig")
      ctx = FixContext.record_attempt(ctx, :goal_fulfillment, "op-orig", validation, "feedback")

      # Persisted history is already small: the digest is taken at record time.
      [record] = ctx.history
      refute Map.has_key?(record.failures, "raw_output")
      assert [%{"req_id" => "FR-5"}] = record.failures["requirements_met"]
      assert byte_size(:erlang.term_to_binary(FixContext.to_map(ctx))) < 1_000

      prompt = FixContext.format_for_prompt(ctx)
      refute prompt =~ ~s({"type":"assistant") or prompt =~ "raw_output"
      refute prompt =~ "accepted in an earlier validation round"
      assert prompt =~ "FR-5" and prompt =~ "Math.min" and prompt =~ "FR-5 unmet"
      assert prompt =~ "could not be parsed"
    end

    test "digest/1 shrinks a history persisted before it existed, and leaves quality-gate failures alone" do
      legacy = %{
        "overall_verdict" => "fail",
        "raw_output" => "x",
        "requirements_met" => [%{"met" => true}]
      }

      assert FixContext.digest(legacy) == %{"overall_verdict" => "fail"}
      assert FixContext.digest(%{"errors" => ["e1"]}) == %{"errors" => ["e1"]}
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
