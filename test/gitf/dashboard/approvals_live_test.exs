defmodule GiTF.Dashboard.ApprovalsLiveTest do
  @moduledoc """
  The Catwalk's approve and reject buttons had never worked.

  `approval` on this page is an `:approval_requests` record, so
  `approval.id` is the REQUEST id (`apr-…`). Both buttons passed it as
  `phx-value-id`, the handlers stored it as `action_id`, and
  `confirm_approve` handed it to `GiTF.Override.approve/2` — which wants a
  MISSION id. `Missions.store_artifact("apr-…", …)` answered
  `{:error, :not_found}` and the operator got a flash they could miss.
  Three clicks on the live box, `approval_status` still `:pending`.

  The fix keeps the two ids apart, because `action_id` is also the modal
  targeting key: swapping the buttons to the mission id would have fixed
  the write and broken targeting the moment two requests were pending.
  Both properties are pinned below, and the assertions are against
  `Override.approval_status/1` rather than flash text — a flash proves
  only that we rendered a sentence.
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

  defp pending(name \\ "needs-a-decision") do
    {:ok, mission} =
      Archive.insert(:missions, %{
        name: name,
        goal: "ship #{name}",
        status: "active",
        sector_id: "no-such-sector",
        current_phase: "awaiting_approval",
        artifacts: %{
          "validation" => %{
            "overall_verdict" => "pass",
            "requirements_met" => [%{"req_id" => "FR-1", "met" => true}]
          }
        },
        ops: []
      })

    {:ok, request} =
      Archive.insert(:approval_requests, %{
        mission_id: mission.id,
        quest_name: name,
        goal: "ship #{name}",
        risk_levels: [:normal],
        files_touched: [],
        job_count: 1,
        status: "pending",
        requested_at: DateTime.utc_now()
      })

    %{mission: mission, request: request}
  end

  defp open_page, do: live(build_conn(), "/dashboard/approvals")

  defp click_action(view, action, request_id) do
    view
    |> element(~s{button[phx-click="#{action}"][phx-value-id="#{request_id}"]})
    |> render_click()
  end

  defp confirm(view, action) do
    view |> element(~s{button[phx-click="#{action}"]}) |> render_click()
  end

  describe "the page renders" do
    test "a pending approval shows up with its mission" do
      %{mission: mission} = pending()

      {:ok, _view, html} = open_page()

      assert html =~ mission.id
      assert html =~ "needs-a-decision"
    end
  end

  describe "approve" do
    test "a real approve lands on the MISSION, not the request record" do
      %{mission: mission, request: request} = pending()
      assert Override.approval_status(mission.id) == :pending

      {:ok, view, _html} = open_page()

      click_action(view, "show_approve", request.id)
      confirm(view, "confirm_approve")

      # The whole bug in one assertion: this stayed :pending for every
      # operator who ever pressed this button.
      assert Override.approval_status(mission.id) == :approved
      assert GiTF.Missions.get_artifact(mission.id, "approval")["approved"] == true
    end

    test "the decided request leaves the queue and the operator is told" do
      %{mission: mission, request: request} = pending()

      {:ok, view, _html} = open_page()
      click_action(view, "show_approve", request.id)
      html = confirm(view, "confirm_approve")

      assert html =~ "No pending approvals"
      refute html =~ mission.id

      # AppLayout dropped :flash while rendering @flash, so every
      # put_flash on the Catwalk went to a void — including the error the
      # operator should have seen when approve failed.
      assert html =~ "Approved."
    end
  end

  describe "reject" do
    test "reject had the identical defect and now lands on the mission" do
      %{mission: mission, request: request} = pending()

      {:ok, view, _html} = open_page()

      click_action(view, "show_reject", request.id)

      view
      |> element("#reject-notes")
      |> render_change(%{"notes" => "the gap is behavioral, not cosmetic"})

      confirm(view, "confirm_reject")

      assert Override.approval_status(mission.id) == :rejected

      artifact = GiTF.Missions.get_artifact(mission.id, "approval")
      assert artifact["approved"] == false
      assert artifact["reason"] == "the gap is behavioral, not cosmetic"
    end

    test "a blank reason refuses and leaves the approval pending" do
      %{mission: mission, request: request} = pending()

      {:ok, view, _html} = open_page()
      click_action(view, "show_reject", request.id)
      html = confirm(view, "confirm_reject")

      assert html =~ "Rejection reason is required"
      assert Override.approval_status(mission.id) == :pending
    end
  end

  describe "a request whose mission is gone" do
    test "flashes an error naming the request instead of silently doing nothing" do
      {:ok, request} =
        Archive.insert(:approval_requests, %{
          mission_id: nil,
          quest_name: "orphan",
          goal: "orphaned request",
          status: "pending",
          requested_at: DateTime.utc_now()
        })

      {:ok, view, _html} = open_page()

      click_action(view, "show_approve", request.id)
      html = confirm(view, "confirm_approve")

      assert html =~ "carries no mission id"
      assert html =~ request.id

      # Still alive — a stale request must not take the page down.
      assert render(view) =~ "Approvals"
    end
  end

  describe "modal targeting" do
    # The regression the naive fix (swap the buttons to mission_id) would
    # have caused: `action_id` is what decides WHICH card expands.
    test "with two approvals pending, only the clicked card opens and only it decides" do
      %{mission: first} = pending("first-mission")
      %{mission: second, request: second_request} = pending("second-mission")

      {:ok, view, _html} = open_page()

      click_action(view, "show_approve", second_request.id)

      # Exactly one card expanded its modal.
      assert view |> render() |> confirm_button_count() == 1

      confirm(view, "confirm_approve")

      assert Override.approval_status(second.id) == :approved
      assert Override.approval_status(first.id) == :pending
    end

    test "cancelling closes the modal and decides nothing" do
      %{mission: mission, request: request} = pending()

      {:ok, view, _html} = open_page()
      click_action(view, "show_approve", request.id)
      assert view |> render() |> confirm_button_count() == 1

      confirm(view, "cancel_action")

      assert view |> render() |> confirm_button_count() == 0
      assert Override.approval_status(mission.id) == :pending
    end
  end

  defp confirm_button_count(html) do
    html |> String.split(~s{phx-click="confirm_approve"}) |> length() |> Kernel.-(1)
  end
end
