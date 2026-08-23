defmodule GiTF.IdleStopTest do
  @moduledoc """
  An idle-stop override keeps a billed EC2 box awake, so the property that
  matters most is that it always expires. These pin that, and the bounds
  that stop a typo from turning minutes into days.
  """
  use ExUnit.Case, async: false

  alias GiTF.IdleStop

  setup do
    prev = System.get_env("GITF_HOME")
    dir = Path.join(System.tmp_dir!(), "gitf_idle_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("GITF_HOME", dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      if prev, do: System.put_env("GITF_HOME", prev), else: System.delete_env("GITF_HOME")
    end)

    :ok
  end

  test "an override is active until its expiry" do
    assert {:ok, o} = IdleStop.set(60, 240, reason: "waiting on a PR review")

    assert o.idle_minutes == 60
    assert IdleStop.active().idle_minutes == 60
    assert IdleStop.active().reason == "waiting on a PR review"
    # 4 hours, allowing a minute of slack for clock granularity.
    assert_in_delta IdleStop.remaining_minutes(), 240, 1
  end

  test "an expired override is inert, without needing a sweeper" do
    # Written directly with a past expiry — the file outlives its window
    # whenever nothing has run to clean it up, and must not apply.
    past =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    File.write!(
      IdleStop.path(),
      Jason.encode!(%{
        idle_minutes: 600,
        expires_at: DateTime.to_iso8601(past),
        set_at: DateTime.to_iso8601(past)
      })
    )

    assert IdleStop.active() == nil
    assert IdleStop.remaining_minutes() == 0
  end

  test "clear restores the default immediately" do
    {:ok, _} = IdleStop.set(60, 240)
    assert IdleStop.active()

    :ok = IdleStop.clear()
    assert IdleStop.active() == nil
  end

  test "even the most patient override still expires" do
    # There is deliberately no permanent hold — that is how a box stays up
    # for a month on someone's bill.
    assert {:ok, o} = IdleStop.disable(30)
    assert DateTime.compare(o.expires_at, DateTime.utc_now()) == :gt
    assert IdleStop.remaining_minutes() <= 30
  end

  test "rejects durations and thresholds outside their bounds" do
    assert {:error, {:too_large, :duration_minutes, _}} = IdleStop.set(60, 100_000)
    assert {:error, {:too_large, :idle_minutes, _}} = IdleStop.set(100_000, 60)
    assert {:error, {:too_small, :duration_minutes, _}} = IdleStop.set(60, 0)
    assert {:error, {:not_an_integer, _}} = IdleStop.set("sixty", 60)
  end

  test "a malformed override file is ignored rather than raising" do
    File.write!(IdleStop.path(), "{not json")
    assert IdleStop.active() == nil

    File.write!(IdleStop.path(), Jason.encode!(%{idle_minutes: 60}))
    assert IdleStop.active() == nil
  end

  test "no override when nothing has been set" do
    assert IdleStop.active() == nil
    assert IdleStop.remaining_minutes() == 0
  end
end
