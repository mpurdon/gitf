defmodule GiTF.IDTest do
  use ExUnit.Case, async: true

  describe "generate/1" do
    test "produces an ID with the correct prefix" do
      for prefix <- ~w(ghost job qst cmb cel wag cst)a do
        id = GiTF.ID.generate(prefix)
        assert String.starts_with?(id, "#{prefix}-"), "expected #{id} to start with #{prefix}-"
      end
    end

    test "produces a 6-character lowercase hex suffix" do
      id = GiTF.ID.generate(:ghost)
      [_prefix, suffix] = String.split(id, "-", parts: 2)

      assert String.length(suffix) == 6
      assert suffix =~ ~r/^[0-9a-f]{6}$/
    end

    test "generates unique IDs across calls" do
      ids = for _ <- 1..100, do: GiTF.ID.generate(:job)
      assert length(Enum.uniq(ids)) == 100
    end
  end
end
