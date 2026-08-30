defmodule GiTF.Ghost.WorkerCallMetricsTest do
  @moduledoc """
  The end-to-end assertion behind the gap this closes: run a ghost against
  a CLI subprocess and `provider_perf` has data afterwards.

  Before this, `CallMetrics` had two call sites and ghosts went through
  neither, so a window containing twenty-five finished ghosts reported
  `"providers": []`. These tests fail if that regresses.
  """

  use GiTF.StoreCase

  alias GiTF.Ghost.Worker
  alias GiTF.Runtime.CallMetrics
  alias GiTF.Runtime.CLICallTracker
  alias GiTF.TestDriver.MockClaude
  alias GiTF.Archive

  setup do
    repo_path = create_temp_git_repo()
    gitf_root = create_gitf_workspace()

    {:ok, sector} =
      GiTF.Sector.add(repo_path, name: "call-metrics-sector-#{unique()}")

    {:ok, mission} = Archive.insert(:missions, %{name: "call-metrics-#{unique()}", status: "run"})

    {:ok, op} =
      GiTF.Ops.create(%{
        title: "Instrumented task",
        description: "Do the work",
        mission_id: mission.id,
        sector_id: sector.id
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{
        name: "metrics-ghost",
        status: "starting",
        assigned_model: "sonnet"
      })

    {:ok, _} = GiTF.Ops.assign(op.id, ghost.id)

    %{sector: sector, mission: mission, op: op, ghost: ghost, gitf_root: gitf_root}
  end

  defp unique, do: :erlang.unique_integer([:positive])

  defp create_temp_git_repo do
    path = Path.join(System.tmp_dir!(), "gitf_call_metrics_repo_#{unique()}")
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    File.write!(Path.join(path, "README.md"), "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"], cd: path, stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf!(path) end)
    String.trim(real_path)
  end

  defp create_gitf_workspace do
    path = Path.join(System.tmp_dir!(), "gitf_call_metrics_ws_#{unique()}")
    File.mkdir_p!(Path.join(path, ".gitf"))
    File.write!(Path.join([path, ".gitf", "config.toml"]), "")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp run_ghost(ctx, executable) do
    {:ok, pid} =
      Worker.start_link(
        ghost_id: ctx.ghost.id,
        op_id: ctx.op.id,
        sector_id: ctx.sector.id,
        gitf_root: ctx.gitf_root,
        claude_executable: executable,
        prompt: "hello"
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 60_000
    :ok
  end

  defp recorded_calls do
    Archive.all(:llm_calls)
    |> Enum.filter(&(&1[:kind] in [:cli_call, :cli_run]))
  end

  @tag timeout: 90_000
  test "a ghost run books one record per model call, and provider_perf sees them", ctx do
    {:ok, exe} =
      MockClaude.write_turn_script(System.tmp_dir!(), 3, call_delay_ms: 120, blocks: 2)

    :ok = run_ghost(ctx, exe)

    calls = recorded_calls()

    # Three turns, two content blocks each: six assistant events on the
    # wire, three model calls.
    assert length(calls) == 3
    assert Enum.all?(calls, &(&1[:unit] == :call))
    assert Enum.all?(calls, &(&1[:kind] == :cli_call))
    assert Enum.all?(calls, &(&1[:model] == "claude-sonnet-4-20250514"))
    assert Enum.all?(calls, &(&1[:provider] == "cli"))
    assert Enum.all?(calls, &(&1[:mission_id] == ctx.mission.id))
    assert Enum.all?(calls, &(&1[:output_tokens] == 40))
    assert Enum.all?(calls, &(&1[:input_tokens] == 1_000))
    assert Enum.all?(calls, &(&1[:outcome] == :ok))

    # Real intervals, not a run duration and not zero.
    assert Enum.all?(calls, &(&1[:duration_ms] >= 100))
    assert Enum.all?(calls, &(&1[:duration_ms] < 60_000))

    # The assertion that `provider_perf` would now show something.
    [row] = Enum.filter(CallMetrics.stats(hours: 1), &(&1.provider == "cli"))

    assert row.calls == 3
    assert row.unit == :call
    assert is_number(row.p50_duration_ms)
    assert is_number(row.p95_duration_ms)
    assert is_number(row.mean_tokens_per_sec)
    assert row.error_rate == 0.0
  end

  @tag timeout: 90_000
  test "a CLI that exits non-zero mid-call still books the failure", ctx do
    # Emits an init and a tool result, then dies before answering: a call
    # was in flight, and that is exactly the degradation signal.
    transcript =
      [
        %{"type" => "system", "subtype" => "init"},
        %{"type" => "user", "message" => %{"role" => "user"}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    {:ok, exe} =
      MockClaude.write_script(System.tmp_dir!(), output: transcript, exit_code: 2)

    :ok = run_ghost(ctx, exe)

    assert [record] = recorded_calls()
    # No call ever completed, so the run is booked as a run — never as a
    # call, which would put a whole session into the call percentiles.
    assert record[:unit] == :run
    assert record[:outcome] == :exit_error
    assert is_integer(record[:duration_ms])

    [row] = Enum.filter(CallMetrics.stats(hours: 1), &(&1.provider == "cli"))
    assert row.unit == :run
    assert row.error_rate == 1.0
  end

  test "call and run units never share a percentile bucket" do
    model = "unit-split-#{unique()}"

    :ok =
      CallMetrics.record(%{
        provider: "cli:claude",
        model: model,
        unit: :call,
        kind: :cli_call,
        duration_ms: 4_000,
        outcome: :ok
      })

    :ok =
      CallMetrics.record(%{
        provider: "cli:claude",
        model: model,
        unit: :run,
        kind: :cli_run,
        duration_ms: 360_000,
        outcome: :ok
      })

    rows = CallMetrics.stats(hours: 1) |> Enum.filter(&(&1.model == model))

    assert length(rows) == 2
    assert %{p50_duration_ms: 4_000} = Enum.find(rows, &(&1.unit == :call))
    assert %{p50_duration_ms: 360_000} = Enum.find(rows, &(&1.unit == :run))
  end

  describe "metrics failures are never the ghost's problem" do
    test "a broken tracker swallows its error and leaves the ghost alone" do
      # buffer must be a binary; this raises inside consume/3.
      broken = %CLICallTracker{CLICallTracker.new() | buffer: :not_a_binary}

      assert Worker.track_call_latency_for_test(broken, "{}\n") == broken
      assert Worker.track_call_latency_for_test(nil, "{}\n") == nil
    end

    test "a broken tracker cannot block the flush, and the flush is idempotent" do
      # A healthy tracker books its record…
      healthy = %{ghost_id: "gst-ok", call_tracker: CLICallTracker.new(provider: "cli")}
      before = length(recorded_calls())
      flushed = Worker.flush_call_latency_for_test(healthy, :timeout)
      assert length(recorded_calls()) == before + 1
      assert flushed.call_tracker == nil

      # A second flush (the terminate/2 backstop) writes nothing further.
      assert Worker.flush_call_latency_for_test(flushed, :interrupted) == flushed
      assert length(recorded_calls()) == before + 1

      # …and a tracker that raises inside finish/3 writes nothing and
      # still hands back a clean state instead of killing the ghost.
      broken = %CLICallTracker{CLICallTracker.new() | started_ms: :not_a_number}

      state =
        Worker.flush_call_latency_for_test(%{ghost_id: "gst-x", call_tracker: broken}, :timeout)

      assert state.call_tracker == nil
      assert length(recorded_calls()) == before + 1
    end

    test "a state that predates the tracker field flushes without raising" do
      assert Worker.flush_call_latency_for_test(%{ghost_id: "gst-y"}, :interrupted) ==
               %{ghost_id: "gst-y"}
    end
  end
end
