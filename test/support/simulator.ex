defmodule GiTF.Test.Simulator do
  @moduledoc """
  End-to-end pipeline simulator.

  Creates a real temp git repo (so git / worktree code runs for real) but
  swaps the LLM client out for `GiTF.Test.ScriptedLLMClient` so no external
  API calls happen. Drives a mission through the orchestrator and reports
  every phase transition.

  Reset is idempotent and leak-resistant: each `reset!/0` stops lingering
  ghost workers, wipes the Archive tables, and removes the temp sector.

  ## Usage

      test "happy path" do
        {:ok, ctx} = Simulator.setup_scenario(rules: happy_path_rules())

        {:ok, mission} = Simulator.create_mission(ctx, goal: "Fix button label")
        {:ok, outcome} = Simulator.run(ctx, mission.id, max_ticks: 60)

        assert outcome.status == "completed"
        assert Enum.any?(outcome.phases, &(&1 == "publish"))
      end
  """

  alias GiTF.Archive
  alias GiTF.Test.ScriptedLLMClient
  alias GiTF.Test.StoreHelper

  @tick_interval_ms 100

  # -- Setup / teardown --------------------------------------------------------

  @doc """
  Sets up a full simulation context: temp sector with git repo, scripted
  LLM client configured, Archive cleared, scenario rules loaded.

  Options:

    * `:rules` (required) — list of `ScriptedLLMClient` rules
    * `:sector_name` — defaults to "sim-<unique>"
    * `:files` — map of `path => content` to seed the repo with
  """
  def setup_scenario(opts) do
    rules = Keyword.fetch!(opts, :rules)
    sector_name = Keyword.get(opts, :sector_name, "sim-#{:erlang.unique_integer([:positive])}")
    seed_files = Keyword.get(opts, :files, %{"README.md" => "# sim\n"})

    # Make sure the app-level Archive is healthy. A prior StoreCase test
    # can leave the Archive pointing at a torn-down temp data_dir; the
    # `Archive.insert(:sectors, ...)` below would then return
    # `{:error, :enoent}` and the `{:ok, sector} = ...` bind would
    # crash with CaseClauseError. `restore_app_store/0` is idempotent
    # and fast.
    GiTF.Test.StoreHelper.restore_app_store()

    # Make sure Major is running. The Harness for E2E tests calls
    # `Supervisor.terminate_child + delete_child` on Major, so once
    # the harness exits Major is gone from the supervisor tree.
    # Simulator scenarios rely on Major receiving `:spawn_ready_jobs`
    # to actually launch impl ops; without Major, the impl op is
    # created but stays `pending` forever and the mission stalls at
    # implementation.
    ensure_major_running()

    # Ensure a gitf root exists — phase-ghost spawning calls GiTF.gitf_dir()
    # which needs a .gitf/config.toml somewhere on disk. Use a per-scenario
    # GITF_PATH so parallel scenarios can't step on each other.
    {prior_gitf_path, gitf_root} = ensure_gitf_root(sector_name)

    # Swap LLM client FIRST so any in-flight worker boot picks up the mock.
    prior_client = Application.get_env(:gitf, :llm_client)
    Application.put_env(:gitf, :llm_client, ScriptedLLMClient)

    # Seed a real git repo in a temp dir.
    sector_path = build_sector(sector_name, seed_files)

    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: sector_name,
        path: sector_path,
        sync_strategy: "auto_merge"
      })

    {:ok, _} = ScriptedLLMClient.start_scenario(rules)

    ctx = %{
      sector: sector,
      sector_path: sector_path,
      gitf_root: gitf_root,
      prior_gitf_path: prior_gitf_path,
      prior_client: prior_client,
      scenario_rules: rules
    }

    {:ok, ctx}
  end

  # Start Major if it's not running. Best-effort — falls back silently
  # if start_link returns `{:error, _}` so a misconfigured test
  # environment doesn't crash setup; the test will still time out
  # with a clear "mission stalled at implementation" snapshot.
  defp ensure_major_running do
    if Process.whereis(GiTF.Major) == nil do
      gitf_root =
        case GiTF.gitf_dir() do
          {:ok, root} -> root
          _ -> System.tmp_dir!()
        end

      case GiTF.Major.start_link(gitf_root: gitf_root) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    :ok
  end

  defp ensure_gitf_root(sector_name) do
    root = Path.join([System.tmp_dir!(), "gitf-sim-root", sector_name])
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, ".gitf"))
    File.write!(Path.join([root, ".gitf", "config.toml"]), "")

    prior = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", root)

    {prior, root}
  end

  @doc """
  Tears down a scenario: stops sector-scoped ghost workers, deletes all
  records tied to the test sector, removes the temp sector directory,
  restores the original LLM client.

  Scoped by `sector_id` so it can be used against the real application
  supervision tree (Archive, Major, MissionSupervisor) without
  disturbing other missions in the Archive.

  Safe to call even if setup failed partway through.
  """
  def reset!(ctx) do
    sector_id = get_in(ctx, [:sector, :id])

    if sector_id do
      # Kill any ghost workers whose ops belong to this sector before
      # we delete their op/ghost records — otherwise a live worker
      # could re-insert records mid-reset.
      stop_sector_ghost_workers(sector_id)

      purge_sector_records(sector_id)
    end

    ScriptedLLMClient.stop()

    case ctx do
      %{sector_path: path} when is_binary(path) ->
        # Non-raising: a lingering ghost/worktree write can race the recursive
        # delete during teardown; that must not fail an otherwise-passing test.
        File.rm_rf(path)

      _ ->
        :ok
    end

    case ctx do
      %{prior_client: nil} ->
        Application.delete_env(:gitf, :llm_client)

      %{prior_client: prior} ->
        Application.put_env(:gitf, :llm_client, prior)

      _ ->
        :ok
    end

    case ctx do
      %{gitf_root: path} when is_binary(path) -> File.rm_rf!(path)
      _ -> :ok
    end

    case ctx do
      %{prior_gitf_path: nil} -> System.delete_env("GITF_PATH")
      %{prior_gitf_path: prior} when is_binary(prior) -> System.put_env("GITF_PATH", prior)
      _ -> :ok
    end

    :ok
  end

  defp stop_sector_ghost_workers(sector_id) do
    Archive.filter(:ghosts, fn g -> g[:sector_id] == sector_id end)
    |> Enum.each(fn ghost ->
      case GiTF.Ghost.Worker.lookup(ghost.id) do
        {:ok, pid} when is_pid(pid) ->
          try do
            GenServer.stop(pid, :shutdown, 2_000)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Returns a 0-arity function suitable as a scenario `:side_effect` that
  commits the given files to whichever impl ghost worktree is currently
  mid-LLM-call in the given sector. Auto-resolves the mission by picking
  the only active one for the sector — valid when scenarios run one
  mission at a time.
  """
  def impl_commit_hook(sector_id, files, message \\ "sim: impl commit") do
    fn ->
      case Archive.filter(:missions, fn m ->
             m[:sector_id] == sector_id and m[:status] not in ["completed", "failed", "closed"]
           end) do
        [mission] ->
          simulate_impl_commit(mission.id, files, message)

        [] ->
          :ok

        more ->
          raise "impl_commit_hook: expected 1 active mission, got #{length(more)}"
      end
    end
  end

  @doc """
  Simulates an implementation-ghost commit. Finds the impl ghost's shell
  for the given mission, writes the given files, and commits them with
  git. Intended as a `:side_effect` on the "Implement:" rule — without
  this, the ghost worker sees `files_changed: 0` and fails the op.
  """
  def simulate_impl_commit(mission_id, files, message \\ "sim: impl commit") do
    shell = non_phase_impl_shell(mission_id) || newest_shell_for_mission(mission_id)

    if shell == nil do
      raise "simulate_impl_commit: no shell found for mission #{mission_id}"
    end

    path = shell.worktree_path

    Enum.each(files, fn {rel, content} ->
      full = Path.join(path, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    {_, 0} = System.cmd("/usr/bin/git", ["add", "-A"], cd: path, stderr_to_stdout: true)

    {commit_out, commit_code} =
      System.cmd(
        "/usr/bin/git",
        ["-c", "user.email=sim@test", "-c", "user.name=Simulator", "commit", "-m", message],
        cd: path,
        stderr_to_stdout: true
      )

    if commit_code != 0 do
      raise "simulate_impl_commit: git commit failed in #{path}: #{commit_out}"
    end

    :ok
  end

  defp newest_shell_for_mission(mission_id) do
    ops = GiTF.Ops.list(mission_id: mission_id)
    shell_ids = ops |> Enum.map(& &1[:shell_id]) |> Enum.reject(&is_nil/1)

    Archive.filter(:shells, fn s -> s.id in shell_ids end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  # Prefers the shell owned by the ghost of the currently-running
  # implementation (non-phase) op. The op itself doesn't have `shell_id`
  # populated until mark_success runs, so we look it up via the ghost
  # record (which has `shell_id` set on spawn).
  defp non_phase_impl_shell(mission_id) do
    ops = GiTF.Ops.list(mission_id: mission_id)

    impl_op =
      ops
      |> Enum.filter(fn op ->
        op[:phase_job] in [nil, false] and
          op.status in ["running", "assigned"] and
          is_binary(op[:ghost_id])
      end)
      |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
      |> List.first()

    with %{ghost_id: gid} <- impl_op,
         %{shell_id: sid} when is_binary(sid) <- Archive.get(:ghosts, gid),
         %{} = shell <- Archive.get(:shells, sid) do
      shell
    else
      _ -> nil
    end
  end

  defp purge_sector_records(sector_id) do
    purgable =
      [
        {:missions, & &1[:sector_id]},
        {:ops, & &1[:sector_id]},
        {:ghosts, & &1[:sector_id]},
        {:shells, & &1[:sector_id]},
        {:costs, & &1[:sector_id]}
      ]

    mission_ids =
      Archive.filter(:missions, fn m -> m[:sector_id] == sector_id end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    for {collection, fetch_sector} <- purgable do
      Archive.all(collection)
      |> Enum.filter(fn record -> fetch_sector.(record) == sector_id end)
      |> Enum.each(&Archive.delete(collection, &1.id))
    end

    for table <- [:mission_phase_transitions, :links, :events, :triage_feedback] do
      Archive.all(table)
      |> Enum.filter(fn r -> MapSet.member?(mission_ids, r[:mission_id] || r[:entity_id]) end)
      |> Enum.each(&Archive.delete(table, &1[:id] || &1[:seq]))
    end

    Archive.delete(:sectors, sector_id)
  end

  defp build_sector(name, seed_files) do
    base = Path.join([System.tmp_dir!(), "gitf-sim", name])
    File.rm_rf!(base)
    File.mkdir_p!(base)

    StoreHelper.init_git_repo!(base)

    Enum.each(seed_files, fn {rel, content} ->
      full = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    if seed_files != %{} do
      git(base, ["add", "."])
      git(base, ["commit", "-m", "seed sim files"])
    end

    base
  end

  defp git(cwd, args) do
    {out, code} = System.cmd("/usr/bin/git", args, cd: cwd, stderr_to_stdout: true)

    if code != 0 do
      raise "git #{Enum.join(args, " ")} failed in #{cwd}: #{out}"
    end

    out
  end

  # -- Mission lifecycle -------------------------------------------------------

  @doc """
  Creates a mission linked to the scenario's sector.

  Supports `:goal` (required), `:name`, `:cost_cap_usd`, and `:issue_ref`.
  """
  def create_mission(ctx, opts) do
    goal = Keyword.fetch!(opts, :goal)
    name = Keyword.get(opts, :name, goal |> String.slice(0, 40))

    attrs =
      %{
        goal: goal,
        sector_id: ctx.sector.id,
        name: name
      }
      |> maybe_put(:cost_cap_usd, Keyword.get(opts, :cost_cap_usd))
      |> maybe_put(:issue_ref, Keyword.get(opts, :issue_ref))

    GiTF.Missions.create(attrs)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Starts the mission and polls until it reaches a terminal state or
  `max_ticks` is exhausted. Returns `{:ok, outcome}` with collected
  phase history and final status.

  Options:

    * `:max_ticks` (default 60) — poll iterations at `@tick_interval_ms` each
    * `:terminal_statuses` (default `["completed", "failed", "killed", "closed"]`)
  """
  def run(_ctx, mission_id, opts \\ []) do
    max_ticks = Keyword.get(opts, :max_ticks, 60)

    terminal =
      Keyword.get(opts, :terminal_statuses, ~w(completed failed killed closed))

    case GiTF.Major.Orchestrator.start_quest(mission_id) do
      {:ok, _} -> poll_until_terminal(mission_id, max_ticks, terminal, [], nil)
      {:error, reason} -> {:error, {:start_quest_failed, reason}}
    end
  end

  defp poll_until_terminal(mid, 0, _terminal, seen_phases, last_status) do
    {mission_snapshot, ops_snapshot} =
      case GiTF.Missions.get(mid) do
        {:ok, m} -> {m, m.ops |> Enum.map(&op_summary/1)}
        _ -> {nil, []}
      end

    {:timeout,
     %{
       mission_id: mid,
       status: last_status,
       phases_seen: Enum.reverse(seen_phases),
       reason: :max_ticks_reached,
       mission: mission_snapshot,
       ops: ops_snapshot,
       llm_calls: ScriptedLLMClient.calls() |> Enum.reverse(),
       unmatched_llm: ScriptedLLMClient.unmatched_count()
     }}
  end

  defp poll_until_terminal(mid, ticks, terminal, seen_phases, _last_status) do
    Process.sleep(@tick_interval_ms)

    case GiTF.Missions.get(mid) do
      {:ok, mission} ->
        phase = mission.current_phase
        status = mission.status

        seen =
          if seen_phases == [] or hd(seen_phases) != phase do
            [phase | seen_phases]
          else
            seen_phases
          end

        artifacts = Map.get(mission, :artifacts, %{})
        ops_done = Enum.count(mission.ops, &(&1.status in ["done", "failed"]))
        ops_pending = Enum.count(mission.ops, &(&1.status in ["pending", "assigned", "running"]))

        # Silent by default. Set GITF_SIM_TRACE=1 to see tick-by-tick state.
        if System.get_env("GITF_SIM_TRACE") == "1" and rem(ticks, 10) == 0 do
          artifact_keys = Map.keys(artifacts) |> Enum.sort()

          op_states =
            Enum.map(mission.ops, fn op ->
              fc = op[:files_changed]

              "#{op.id}[#{op.status}#{if op[:phase_job], do: "/#{op[:phase]}", else: "/impl"}" <>
                "#{if fc, do: "/fc=#{fc}"}]"
            end)
            |> Enum.join(" ")

          IO.puts(
            "[sim tick #{ticks}] phase=#{phase} status=#{status} ops_done=#{ops_done} " <>
              "ops_pending=#{ops_pending} artifacts=#{inspect(artifact_keys)} " <>
              "ops=#{op_states}"
          )
        end

        cond do
          status in terminal ->
            outcome = %{
              mission_id: mid,
              status: status,
              current_phase: phase,
              post_processing_status: mission[:post_processing_status],
              phases_seen: Enum.reverse(seen),
              llm_calls: ScriptedLLMClient.calls() |> Enum.reverse(),
              mission: mission
            }

            {:ok, outcome}

          true ->
            # Nudge the orchestrator — our scripted LLM may have answered
            # several calls and stored artifacts without any real ghost
            # event firing advance_quest.
            GiTF.Major.Orchestrator.advance_quest(mid)
            poll_until_terminal(mid, ticks - 1, terminal, seen, status)
        end

      {:error, reason} ->
        {:error, {:mission_not_found, reason}}
    end
  end

  defp op_summary(op) do
    %{
      id: op.id,
      status: op.status,
      phase: op[:phase],
      phase_job: op[:phase_job],
      title: op[:title] |> to_string() |> String.slice(0, 60)
    }
  end
end
