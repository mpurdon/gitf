defmodule GiTF.Dashboard.MissionPipelineTest do
  @moduledoc """
  The Phase Pipeline rendered msn-ac0539 as **sync — actively merging**
  for the twelve hours it sat blocked on a human. `awaiting_approval` had
  been subtracted from the display list and aliased to `sync`, so the one
  phase meaning "the factory has stopped and a person is the blocker" was
  drawn as the factory working.

  These assert against the rendered step classes, because the class is
  what the operator actually sees.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GiTF.{Archive, Override}

  @endpoint GiTF.Web.Endpoint

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    endpoint_alive? =
      case Process.whereis(GiTF.Web.Endpoint) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    ets_ok? =
      try do
        GiTF.Web.Endpoint.config(:pubsub_server)
        true
      rescue
        ArgumentError -> false
      end

    if !(endpoint_alive? and ets_ok?) do
      GiTF.Test.StoreHelper.safe_stop(GiTF.Web.Endpoint)
      Process.sleep(50)
      current = Application.get_env(:gitf, GiTF.Web.Endpoint, [])
      Application.put_env(:gitf, GiTF.Web.Endpoint, Keyword.put(current, :server, false))
      {:ok, _} = GiTF.Web.Endpoint.start_link([])
    end

    :ok
  end

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "pipeline",
            goal: "render the gate",
            status: "active",
            sector_id: "no-such-sector",
            artifacts: %{},
            ops: []
          },
          fields
        )
      )

    m
  end

  defp render_pipeline(mission) do
    {:ok, _view, html} = live(build_conn(), "/dashboard/missions/#{mission.id}")
    html
  end

  # The class on the step whose phx-value-phase is `phase`.
  defp step_class(html, phase) do
    case Regex.run(~r/class="step ([^"]*)"[^>]*phx-value-phase="#{phase}"/, html) do
      [_, classes] -> String.trim(classes)
      nil -> nil
    end
  end

  describe "the gate is on the strip at all" do
    test "awaiting_approval renders as its own step, labelled approval" do
      html = render_pipeline(mission!(%{current_phase: "awaiting_approval"}))

      assert html =~ ~s{phx-value-phase="awaiting_approval"}

      # "awaiting_approval" crowds the strip; the id stays canonical
      # everywhere else, including the phx-value above.
      assert html =~ ~r/class="step-label"[^>]*>\s*approval/
    end

    test "every orchestrator phase has a step" do
      html = render_pipeline(mission!(%{current_phase: "validation"}))

      for phase <- GiTF.Major.Orchestrator.phases() do
        assert html =~ ~s{phx-value-phase="#{phase}"}, "#{phase} is missing from the pipeline"
      end
    end
  end

  describe "a mission held on the gate" do
    setup do
      %{html: render_pipeline(mission!(%{current_phase: "awaiting_approval"}))}
    end

    test "approval is the ACTIVE step", %{html: html} do
      assert step_class(html, "awaiting_approval") == "step-active"
    end

    test "sync is not active — the bug rendered this mission as merging", %{html: html} do
      refute step_class(html, "sync") == "step-active"
      assert step_class(html, "sync") == "step-future"
    end

    test "validation and everything before it are done", %{html: html} do
      for phase <- ~w(triage research requirements design planning implementation validation) do
        assert step_class(html, phase) == "step-done", "#{phase} should read done"
      end
    end

    test "sync, publish and scoring are still to come", %{html: html} do
      for phase <- ~w(sync simplify publish scoring) do
        assert step_class(html, phase) == "step-future", "#{phase} should read future"
      end
    end

    test "nothing renders as pending", %{html: html} do
      # The `|| 0` index fallback used to collapse an unknown phase to
      # "pending" — a position it had never actually occupied.
      assert step_class(html, "pending") == "step-done"
      refute step_class(html, "pending") == "step-active"
    end

    test "the gate is not dimmed as skipped while it is live", %{html: html} do
      refute step_class(html, "awaiting_approval") =~ "skipped"
    end
  end

  describe "a mission that never needed approval" do
    test "the gate renders SKIPPED once the mission is past it" do
      mission = mission!(%{current_phase: "sync"})

      assert Override.approval_status(mission.id) == :not_required
      assert step_class(render_pipeline(mission), "awaiting_approval") == "step-skipped"
    end

    test "a completed mission that never gated is skipped too" do
      mission = mission!(%{current_phase: "completed", status: "completed"})

      assert step_class(render_pipeline(mission), "awaiting_approval") == "step-skipped"
    end
  end

  describe "a mission that WAS approved" do
    test "renders done, not skipped" do
      mission = mission!(%{current_phase: "sync"})

      {:ok, _} =
        Archive.insert(:approval_requests, %{
          mission_id: mission.id,
          quest_name: "pipeline",
          goal: "x",
          status: "pending",
          requested_at: DateTime.utc_now()
        })

      {:ok, _} = Override.approve(mission.id, %{approved_by: "matthew@purdonmoi.com"})

      assert step_class(render_pipeline(mission), "awaiting_approval") == "step-done"
    end

    test "an auto-timeout approval also renders done — it did happen" do
      mission = mission!(%{current_phase: "sync"})
      {:ok, _} = Override.approve(mission.id, %{approved_by: "auto_timeout"})

      assert step_class(render_pipeline(mission), "awaiting_approval") == "step-done"
    end
  end

  describe "a mission that has not reached the gate" do
    test "approval is FUTURE — neither done nor skipped" do
      html = render_pipeline(mission!(%{current_phase: "validation"}))

      assert step_class(html, "awaiting_approval") == "step-future"
    end

    test "a gate that may still fire is never dimmed" do
      for phase <- ~w(implementation validation) do
        html = render_pipeline(mission!(%{current_phase: phase}))

        refute step_class(html, "awaiting_approval") == "step-skipped",
               "at #{phase} the gate can still fire"
      end
    end
  end

  describe "the gate is clickable for its decisions" do
    test "an approved mission's gate offers its decisions" do
      mission = mission!(%{current_phase: "sync"})
      {:ok, _} = Override.approve(mission.id, %{approved_by: "matthew@purdonmoi.com"})

      # The widget's header promises "click a marked phase for its
      # decisions"; the most decision-laden phase in the run had no mark.
      {:ok, mission} = GiTF.Missions.get(mission.id)

      assert GiTF.Dashboard.MissionDetailLive.phase_detail(mission, "awaiting_approval") ==
               :decisions
    end

    test "the decision artifact is stored under approval, not the phase id" do
      assert GiTF.Dashboard.MissionDetailLive.artifact_key("awaiting_approval") == "approval"
      assert GiTF.Dashboard.MissionDetailLive.artifact_key("validation") == "validation"
    end
  end

  describe "the overview mini-pipeline agrees with the detail pipeline" do
    # Both widgets aliased awaiting_approval to sync INDEPENDENTLY. They
    # now share GiTF.Approval.gate_state/1, and the mini-pipeline encodes
    # the answer in each dot's title.
    defp render_overview, do: elem(live(build_conn(), "/dashboard"), 2)

    test "a held mission shows the gate as HELD, not as sync" do
      mission!(%{current_phase: "awaiting_approval", name: "held-one"})

      html = render_overview()

      assert html =~ "approval — HELD, waiting on a human"
    end

    test "a mission that never gated shows the dot as skipped" do
      mission!(%{current_phase: "sync", name: "never-gated"})

      html = render_overview()

      assert html =~ "approval — skipped, nothing needed approving"
    end

    test "a mission before the gate says neither" do
      mission!(%{current_phase: "validation", name: "still-working"})

      html = render_overview()

      refute html =~ "approval — HELD"
      refute html =~ "approval — skipped"
    end

    test "the two widgets read the same mission the same way" do
      for {phase, status} <- [
            {"awaiting_approval", :held},
            {"validation", :future},
            {"sync", :skipped}
          ] do
        mission = mission!(%{current_phase: phase})

        # The detail stepper's skipped treatment and the overview's dot
        # both come from this one call, so they cannot diverge again.
        assert GiTF.Approval.gate_state(mission) == status
      end
    end
  end

  describe "the decisions badges" do
    test "name the outcome and who decided it" do
      badges =
        GiTF.Dashboard.MissionDetailLive.decisions("awaiting_approval", %{
          "approved" => true,
          "approved_by" => "matthew@purdonmoi.com",
          "approved_at" => "2026-08-30T12:00:00Z"
        })

      assert {"decision", "approved", "green"} in badges
      assert {"by", "matthew@purdonmoi.com", "grey"} in badges
    end

    test "call out an auto-decision — nobody read it" do
      badges =
        GiTF.Dashboard.MissionDetailLive.decisions("awaiting_approval", %{
          "approved" => true,
          "approved_by" => "auto_timeout"
        })

      assert {"by", "auto_timeout", "yellow"} in badges
      assert {"human review", "none — auto-decided on timeout", "yellow"} in badges
    end

    test "a rejection reads red" do
      badges =
        GiTF.Dashboard.MissionDetailLive.decisions("awaiting_approval", %{
          "approved" => false,
          "rejected_by" => "matthew@purdonmoi.com",
          "reason" => "the gap is behavioral"
        })

      assert {"decision", "rejected", "red"} in badges
    end
  end
end
