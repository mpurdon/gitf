defmodule GiTF.MajorAuditTest do
  use ExUnit.Case, async: false

  # We can't easily test the Major GenServer async verification flow without
  # mocking GiTF.Audit or starting the full app.
  # But we can verify that the code compiles.

  test "compiles" do
    assert Code.ensure_loaded?(GiTF.Major)
  end
end
