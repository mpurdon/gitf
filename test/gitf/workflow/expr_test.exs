defmodule GiTF.Workflow.ExprTest do
  use ExUnit.Case, async: true

  alias GiTF.Workflow.Expr

  defp bind(artifact \\ %{}, mission \\ %{}), do: %{artifact: artifact, mission: mission}

  describe "literals & truthiness" do
    test "bare booleans and nil" do
      assert Expr.eval("true", bind()) == {:ok, true}
      assert Expr.eval("false", bind()) == {:ok, false}
      assert Expr.eval("nil", bind()) == {:ok, false}
    end
  end

  describe "path access" do
    test "reads nested artifact keys, atom or string" do
      art = %{"skip_flags" => %{"research" => true}, complexity: "minimal"}
      assert Expr.eval("artifact.skip_flags.research == true", bind(art)) == {:ok, true}
      assert Expr.eval("artifact.complexity == \"minimal\"", bind(art)) == {:ok, true}
    end

    test "missing key is nil, not a crash" do
      assert Expr.eval("artifact.nope == nil", bind(%{})) == {:ok, true}
      assert Expr.eval("artifact.a.b.c == nil", bind(%{})) == {:ok, true}
      assert Expr.eval("artifact.nope", bind(%{})) == {:ok, false}
    end

    test "reads mission fields" do
      assert Expr.eval("mission.review_plan == true", bind(%{}, %{review_plan: true})) ==
               {:ok, true}
    end

    test "nil artifact binding is tolerated" do
      assert Expr.eval("artifact.x == true", bind(nil)) == {:ok, false}
    end
  end

  describe "comparisons & membership" do
    test "==, !=, ordering" do
      assert Expr.eval("artifact.n == 3", bind(%{"n" => 3})) == {:ok, true}
      assert Expr.eval("artifact.n != 3", bind(%{"n" => 3})) == {:ok, false}
      assert Expr.eval("artifact.n >= 3", bind(%{"n" => 3})) == {:ok, true}
      assert Expr.eval("artifact.n < 3", bind(%{"n" => 5})) == {:ok, false}
    end

    test "in a list literal" do
      art = %{"complexity" => "normal"}

      assert Expr.eval("artifact.complexity in [\"minimal\", \"normal\"]", bind(art)) ==
               {:ok, true}

      assert Expr.eval("artifact.complexity in [\"complex\"]", bind(art)) == {:ok, false}
    end
  end

  describe "boolean combinators" do
    test "and / or / not, with both spellings" do
      b = bind(%{"a" => true, "b" => false})
      assert Expr.eval("artifact.a and not artifact.b", b) == {:ok, true}
      assert Expr.eval("artifact.a && !artifact.b", b) == {:ok, true}
      assert Expr.eval("artifact.b or artifact.a", b) == {:ok, true}
      assert Expr.eval("artifact.b and artifact.a", b) == {:ok, false}
    end
  end

  describe "validate/1 — static checks" do
    test "accepts well-formed expressions" do
      assert Expr.validate("artifact.x == true") == :ok
      assert Expr.validate("mission.y in [1, 2] or not artifact.z") == :ok
    end

    test "rejects function calls and unknown variables" do
      assert {:error, _} = Expr.validate("File.read!(\"x\")")
      assert {:error, _} = Expr.validate("System.get_env(\"X\")")
      assert {:error, _} = Expr.validate("foo.bar == 1")
      assert {:error, _} = Expr.validate("artifact.x + 1 == 2")
    end

    test "rejects garbage" do
      assert {:error, _} = Expr.validate("=== nope")
      assert {:error, _} = Expr.validate("artifact.")
    end
  end

  test "eval refuses to run a non-whitelisted expression" do
    assert {:error, _} = Expr.eval("File.read!(\"/etc/passwd\")", bind())
  end
end
