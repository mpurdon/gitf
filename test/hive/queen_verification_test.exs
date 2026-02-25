defmodule Hive.QueenVerificationTest do
  use ExUnit.Case, async: false
  
  # We can't easily test the Queen GenServer async verification flow without
  # mocking Hive.Verification or starting the full app.
  # But we can verify that the code compiles.
  
  test "compiles" do
    assert Code.ensure_loaded?(Hive.Queen)
  end
end
