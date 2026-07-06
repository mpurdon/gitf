defmodule GiTF.AramakiTest do
  use ExUnit.Case, async: false

  alias GiTF.Aramaki
  alias GiTF.Aramaki.{Intake, Policy}

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_aramaki_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sector} =
      GiTF.Archive.insert(:sectors, %{
        name: "repo",
        github_owner: "acme",
        github_repo: "widget"
      })

    %{tmp: tmp, sector: sector}
  end

  defp issue(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 42,
        "title" => "Crash on empty input",
        "body" => "Steps to reproduce...",
        "state" => "open",
        "html_url" => "https://github.com/acme/widget/issues/42",
        "labels" => [%{"name" => "gitf:build"}, %{"name" => "bug"}],
        "user" => %{"login" => "human"}
      },
      overrides
    )
  end

  defp event(issue, action \\ "labeled") do
    %{
      "action" => action,
      "issue" => issue,
      "repository" => %{"full_name" => "acme/widget"}
    }
  end

  describe "Policy.admit_issue?/2" do
    test "admits a labeled open issue with a bug priority" do
      assert {:admit, 1} = Policy.admit_issue?(issue())
    end

    test "rejects an unlabeled issue" do
      assert {:reject, :not_labeled} =
               Policy.admit_issue?(issue(%{"labels" => [%{"name" => "question"}]}))
    end

    test "rejects a pull request arriving on the issues endpoint" do
      assert {:reject, :is_pull_request} =
               Policy.admit_issue?(issue(%{"pull_request" => %{"url" => "x"}}))
    end

    test "rejects the factory's own activity (loop prevention)" do
      assert {:reject, :own_activity} =
               Policy.admit_issue?(issue(%{"user" => %{"login" => "gitf-bot"}}),
                 bot_login: "gitf-bot"
               )
    end

    test "security outranks bug outranks feature" do
      assert Policy.priority(["security"]) < Policy.priority(["bug"])
      assert Policy.priority(["bug"]) < Policy.priority(["feature"])
    end
  end

  describe "Intake.dispatch/1" do
    test "creates a deduped pending mission for a labeled issue", %{sector: sector} do
      assert {:ok, :admitted, mission} = Intake.dispatch(event(issue()))
      assert mission.status == "pending"
      assert mission.sector_id == sector.id
      assert mission.source == "github_issue"
      assert mission.aramaki_priority == 1

      # Re-dispatching the same issue dedupes rather than duplicating.
      assert {:ok, :deduped, ^mission} = Intake.dispatch(event(issue(), "edited"))
      assert length(GiTF.Archive.all(:missions)) == 1
    end

    test "ignores an issue for an untracked repo" do
      payload = %{
        "action" => "labeled",
        "issue" => issue(),
        "repository" => %{"full_name" => "someone/else"}
      }

      assert {:ok, :ignored, :untracked_repo} = Intake.dispatch(payload)
    end

    test "ignores an unlabeled issue" do
      assert {:ok, :ignored, :not_labeled} =
               Intake.dispatch(event(issue(%{"labels" => []})))
    end
  end

  describe "admit_pending/0 capacity gate" do
    test "does not start more than max_concurrent", %{sector: sector} do
      # Two pending github_issue missions, cap of 1 → only one admitted.
      Application.put_env(:gitf, :aramaki, enabled: true, trigger_label: "gitf:build", max_concurrent: 1)
      on_exit(fn -> Application.delete_env(:gitf, :aramaki) end)

      for n <- [1, 2] do
        {:ok, _} =
          GiTF.Missions.create(%{
            goal: "issue #{n}",
            sector_id: sector.id,
            source: "github_issue",
            aramaki_priority: 2,
            source_issue: %{key: "acme/widget##{n}", repo: "acme/widget", number: n}
          })
      end

      # start_quest will fail fast in the test env (no ghosts), but the
      # capacity math still caps how many we ATTEMPT to admit.
      admitted = Aramaki.admit_pending()
      assert admitted <= 1
    end
  end
end
