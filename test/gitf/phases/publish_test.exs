defmodule GiTF.Phases.PublishTest do
  use GiTF.StoreCase

  alias GiTF.Phases.Publish
  alias GiTF.Workflow
  alias GiTF.Workflow.{Advancer, Phase}

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(%{name: "p", goal: "x", status: "active", sector_id: "fe", artifacts: %{}}, attrs)
      )

    m
  end

  describe "verdict/2" do
    test "advance on a normal publish artifact" do
      m = insert_mission!(%{})
      assert Publish.verdict(m, %{"status" => "pr_opened", "pr_url" => "https://github.com/x/y/pull/1"}) == :advance
      assert Publish.verdict(m, %{"status" => "pushed_to_main"}) == :advance
    end

    test "terminal_fail on pr_failed / push_failed / failed" do
      m = insert_mission!(%{})
      assert Publish.verdict(m, %{"status" => "pr_failed", "error" => "rate limit"}) == :terminal_fail
      assert Publish.verdict(m, %{"status" => "push_failed"}) == :terminal_fail
      assert Publish.verdict(m, %{"status" => "failed"}) == :terminal_fail
    end

    test "wait when there's no artifact yet" do
      m = insert_mission!(%{})
      assert Publish.verdict(m, nil) == :wait
    end
  end

  describe "before_advance(:advance)" do
    test "marks the mission user-visibly completed" do
      m = insert_mission!(%{status: "active"})
      Publish.before_advance(m, :advance, %{"status" => "pr_opened"})
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.status == "completed"
      assert reloaded.post_processing_status == "pending"
    end

    test "is a no-op for non-advance verdicts" do
      m = insert_mission!(%{status: "active"})
      Publish.before_advance(m, :fail, %{"status" => "pr_failed"})
      assert GiTF.Archive.get(:missions, m.id).status == "active"
    end
  end

  describe "terminal(:retries_exhausted)" do
    test "fails the mission with a reason derived from the artifact" do
      m = insert_mission!(%{status: "active"})
      Publish.terminal(m, :retries_exhausted, %{"status" => "pr_failed", "error" => "401"})
      reloaded = GiTF.Archive.get(:missions, m.id)
      assert reloaded.status == "failed"
      assert reloaded.failure_reason =~ "Publish failed: status=pr_failed"
    end
  end

  describe "end-to-end via Advancer" do
    # Publish's failure path is `:terminal_fail` (handler-driven), which
    # short-circuits max_retries/on_exhausted. So the YAML only needs a
    # success `next:`; there's no on_fail to declare.
    defp publish_workflow do
      %Workflow{
        name: "p",
        phases: [
          %Phase{id: "publish", handler: GiTF.Phases.Publish, next: "scoring"},
          %Phase{id: "scoring", next: "end"}
        ]
      }
    end

    test ":terminal_fail short-circuits to :retries_exhausted" do
      m =
        insert_mission!(%{
          current_phase: "publish",
          artifacts: %{"publish" => %{"status" => "pr_failed", "error" => "boom"}}
        })

      assert {:retries_exhausted, "publish"} = Advancer.decide(m, publish_workflow())
    end

    test "success → :advance dispatches scoring (and before_advance marked user-visible)" do
      m =
        insert_mission!(%{
          current_phase: "publish",
          status: "active",
          artifacts: %{"publish" => %{"status" => "pr_opened", "pr_url" => "https://example/p/1"}}
        })

      assert {:dispatch, "scoring"} = Advancer.decide(m, publish_workflow())
      # before_advance ran via decide:
      assert GiTF.Archive.get(:missions, m.id).status == "completed"
    end
  end
end
