defmodule GiTF.Cabinet.Discord.GroundingTest do
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Discord.Grounding

  describe "ids/1" do
    test "finds the id shapes an operator would act on" do
      text = "msn-4f2a11 is held; op-915b7a failed on ghost-f53fc0"

      assert Grounding.ids(text) == MapSet.new(["msn-4f2a11", "op-915b7a", "ghost-f53fc0"])
    end

    test "ignores ids of things nobody decides about" do
      # Sector, link and cost ids are plumbing, not decisions.
      assert Grounding.ids("sec-aabbcc lnk-112233 cst-445566") == MapSet.new()
    end

    test "does not match a partial or wrong-length suffix" do
      assert Grounding.ids("msn-4f2a1 msn-4f2a111 msn-ZZZZZZ") == MapSet.new()
    end

    test "junk in, empty set out" do
      for input <- [nil, 42, %{}, ""] do
        assert Grounding.ids(input) == MapSet.new(), inspect(input)
      end
    end
  end

  describe "check/2" do
    test "a reply citing only looked-up ids is grounded" do
      grounded = MapSet.new(["msn-4f2a11", "msn-9c31bd"])

      assert Grounding.check("msn-4f2a11 is running, msn-9c31bd validating", grounded) == :ok
    end

    test "an invented id is caught" do
      # The failure mode that matters: nothing downstream would question
      # this, because a read has no confirmation step.
      grounded = MapSet.new(["msn-4f2a11"])

      assert {:ungrounded, ["msn-deadbe"]} =
               Grounding.check("msn-4f2a11 and msn-deadbe are running", grounded)
    end

    test "several invented ids come back sorted" do
      assert {:ungrounded, ["msn-aaaaaa", "op-bbbbbb"]} =
               Grounding.check("msn-aaaaaa blocked op-bbbbbb", MapSet.new())
    end

    test "a reply naming no ids is grounded even with no tool calls" do
      # A persona answering "everything is asleep" from its snapshot has
      # invented nothing.
      assert Grounding.check("Everything is asleep.", MapSet.new()) == :ok
    end
  end

  describe "annotate/2" do
    test "a grounded reply is returned untouched" do
      grounded = MapSet.new(["msn-4f2a11"])
      reply = "msn-4f2a11 is running."

      assert {^reply, :ok} = Grounding.annotate(reply, grounded)
    end

    test "an ungrounded reply is kept but flagged, naming the id" do
      # Annotated rather than suppressed: a reply that is mostly right is
      # still useful if the operator can see which part is not.
      {annotated, verdict} =
        Grounding.annotate("msn-4f2a11 and msn-deadbe are running", MapSet.new(["msn-4f2a11"]))

      assert verdict == {:ungrounded, ["msn-deadbe"]}
      assert annotated =~ "msn-4f2a11 and msn-deadbe are running"
      assert annotated =~ "msn-deadbe"
      assert annotated =~ "unverified"
      refute annotated =~ "msn-4f2a11 without looking"
    end

    test "the warning reads correctly for one id and for several" do
      {one, _} = Grounding.annotate("msn-aaaaaa", MapSet.new())
      assert one =~ "without looking it up"
      assert one =~ "treat that as unverified"

      {many, _} = Grounding.annotate("msn-aaaaaa op-bbbbbb", MapSet.new())
      assert many =~ "without looking them up"
      assert many =~ "treat those as unverified"
    end
  end
end
