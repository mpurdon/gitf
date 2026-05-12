defmodule GiTF.Vault.WriterTest do
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Vault.Writer

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "vault-writer-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    prior_enabled = Application.get_env(:gitf, :vault_writer_enabled)

    System.put_env("GITF_PATH", gitf_root)
    Application.put_env(:gitf, :vault_writer_enabled, true)

    # Use the canonical module name so telemetry-attached handlers can
    # find the Writer via Process.whereis(GiTF.Vault.Writer). StoreCase
    # gives us module-level isolation; each test module gets a fresh
    # Archive, so canonical-name reuse across modules is safe.
    #
    # The application already runs a supervised GiTF.Vault.Writer under
    # GiTF.Core.Supervisor. We can't just GenServer.stop/1 it — it's a
    # :permanent child, so the (:rest_for_one) supervisor restarts it
    # immediately, racing our start_link for the registered name and, if
    # repeated across tests, blowing Core.Supervisor's restart budget and
    # taking down its siblings (Archive ETS tables included). Instead,
    # terminate it through the supervisor so it stays down, then restore
    # it on exit.
    core_sup = Process.whereis(GiTF.Core.Supervisor)
    if core_sup, do: Supervisor.terminate_child(core_sup, GiTF.Vault.Writer)

    {:ok, pid} = Writer.start_link(debounce_ms: 30)
    name = GiTF.Vault.Writer

    on_exit(fn ->
      # `pid` is linked to the (now-finished) test process, so it may already
      # be on its way down — GenServer.stop/1 would raise :no_process. Tolerate it.
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      if core_sup, do: Supervisor.restart_child(core_sup, GiTF.Vault.Writer)

      if prior_path,
        do: System.put_env("GITF_PATH", prior_path),
        else: System.delete_env("GITF_PATH")

      if prior_enabled,
        do: Application.put_env(:gitf, :vault_writer_enabled, prior_enabled),
        else: Application.delete_env(:gitf, :vault_writer_enabled)

      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root, writer: name}
  end

  defp insert_mission(attrs) do
    {:ok, m} =
      Archive.insert(:missions, Map.merge(%{
        name: "Mission",
        goal: "do the thing",
        status: "pending",
        sector_id: "fe",
        current_phase: "pending",
        priority: :normal,
        artifacts: %{},
        phase_jobs: %{}
      }, attrs))

    m
  end

  defp insert_ghost(attrs \\ %{}) do
    {:ok, g} =
      Archive.insert(:ghosts, Map.merge(%{
        name: "calm-builder-#{:erlang.unique_integer([:positive])}",
        model: "claude-opus-4-7",
        tier: :opus,
        status: :running
      }, attrs))

    g
  end

  defp call_render_mission(writer, mission_id), do: GenServer.cast(writer, {:render_mission, mission_id})
  defp call_render_kanban(writer, sector_id), do: GenServer.cast(writer, {:render_kanban, sector_id})
  defp call_render_ghost(writer, ghost_id), do: GenServer.cast(writer, {:render_ghost, ghost_id})
  defp call_flush(writer), do: GenServer.call(writer, :flush)

  describe "render_mission/1 → file write" do
    test "writes the mission file under Sectors/<id>/Missions/", %{gitf_root: root, writer: w} do
      m = insert_mission(%{name: "Fix login flow", goal: "fix it"})

      call_render_mission(w, m.id)
      :ok = call_flush(w)

      expected =
        Path.join([root, "vault", "Sectors", "fe", "Missions", "#{m.id}-fix-login-flow.md"])

      assert File.exists?(expected)
      body = File.read!(expected)
      assert body =~ "# Fix login flow"
      assert body =~ "phase: \"pending\""
    end

    test "coalesces multiple events for the same mission into one write", %{gitf_root: root, writer: w} do
      m = insert_mission(%{name: "M"})

      for _ <- 1..10, do: call_render_mission(w, m.id)
      :ok = call_flush(w)

      expected =
        Path.join([root, "vault", "Sectors", "fe", "Missions", "#{m.id}-m.md"])

      assert File.exists?(expected)
    end

    test "missing mission is a no-op (no crash, no file)", %{gitf_root: root, writer: w} do
      call_render_mission(w, "msn-nonexistent")
      :ok = call_flush(w)

      missions_dir = Path.join([root, "vault", "Sectors", "fe", "Missions"])
      refute File.dir?(missions_dir) and File.ls!(missions_dir) != []
    end
  end

  describe "render_kanban/1 → kanban file" do
    test "writes 002_kanban.md with frontmatter + lanes", %{gitf_root: root, writer: w} do
      _m1 = insert_mission(%{name: "Pending one", status: "pending"})
      _m2 = insert_mission(%{name: "Active one", status: "implementation"})
      _m3 = insert_mission(%{name: "Done one", status: "completed"})

      call_render_kanban(w, "fe")
      :ok = call_flush(w)

      file = Path.join([root, "vault", "Sectors", "fe", "002_kanban.md"])
      assert File.exists?(file)

      body = File.read!(file)
      assert body =~ "kanban-plugin: basic"
      assert body =~ "## Todo"
      assert body =~ "pending-one"
      assert body =~ "active-one"
      assert body =~ "done-one"
    end
  end

  describe "render_ghost/1 → ghost profile" do
    test "writes Ghosts/<name>.md", %{gitf_root: root, writer: w} do
      g = insert_ghost(%{name: "calm-builder-001"})

      call_render_ghost(w, g.id)
      :ok = call_flush(w)

      file = Path.join([root, "vault", "Ghosts", "calm-builder-001.md"])
      assert File.exists?(file)
      body = File.read!(file)
      assert body =~ "# calm-builder-001"
      assert body =~ "model: \"claude-opus-4-7\""
    end
  end

  describe "render_daily_note/1" do
    test "writes a daily note synchronously", %{gitf_root: root, writer: w} do
      _m = insert_mission(%{name: "InFlight", status: "implementation"})

      assert {:ok, file} = GenServer.call(w, {:render_daily_note, ~D[2026-05-04]})
      assert file == Path.join([root, "vault", "Daily Notes", "2026-05-04.md"])

      body = File.read!(file)
      assert body =~ "# 2026-05-04 — Standup"
      assert body =~ "missions_in_flight: 1"
    end
  end

  describe "flush/0" do
    test "drains pending writes immediately", %{gitf_root: root, writer: w} do
      m = insert_mission(%{name: "Flushable"})

      call_render_mission(w, m.id)
      assert :ok = call_flush(w)

      file =
        Path.join([root, "vault", "Sectors", "fe", "Missions", "#{m.id}-flushable.md"])

      assert File.exists?(file)
    end
  end

  describe "telemetry handlers" do
    setup do
      Writer.attach_telemetry()
      :ok
    end

    test "mission :created event triggers a mission render", %{gitf_root: root, writer: w} do
      m = insert_mission(%{name: "Tele Mission"})

      :telemetry.execute([:gitf, :mission, :created], %{}, %{mission_id: m.id})
      :ok = call_flush(w)

      file =
        Path.join([root, "vault", "Sectors", "fe", "Missions", "#{m.id}-tele-mission.md"])

      assert File.exists?(file)
    end

    test "ghost :spawned event triggers a ghost render", %{gitf_root: root, writer: w} do
      g = insert_ghost(%{name: "tele-ghost"})

      :telemetry.execute([:gitf, :ghost, :spawned], %{}, %{ghost_id: g.id})
      :ok = call_flush(w)

      file = Path.join([root, "vault", "Ghosts", "tele-ghost.md"])
      assert File.exists?(file)
    end

    test "respects vault_writer_enabled flag", %{gitf_root: root, writer: w} do
      Application.put_env(:gitf, :vault_writer_enabled, false)

      m = insert_mission(%{name: "Disabled"})
      :telemetry.execute([:gitf, :mission, :created], %{}, %{mission_id: m.id})
      :ok = call_flush(w)

      file =
        Path.join([root, "vault", "Sectors", "fe", "Missions", "#{m.id}-disabled.md"])

      refute File.exists?(file)
    end
  end
end
