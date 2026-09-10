defmodule GiTF.Aramaki.LifecycleIssueTest do
  @moduledoc """
  What the factory says and does on the issue that prompted a mission —
  and the record it keeps of it. "Did the factory see the merge and act?"
  was unanswerable from inside the factory until `:reported_back` events
  existed; the only evidence lived on GitHub.
  """
  use GiTF.StoreCase

  alias GiTF.Aramaki.Lifecycle

  # A stand-in GitHub: records every call, answers like the real thing.
  defmodule FakeGitHub do
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    post "/repos/:owner/:repo/issues/:num/comments" do
      record(conn, {:comment, conn.body_params["body"]})
      send_resp(conn, 201, "{}")
    end

    post "/repos/:owner/:repo/issues/:num/labels" do
      record(conn, {:label, hd(conn.body_params["labels"])})

      if Agent.get(:fake_github_calls, & &1) |> Enum.any?(&(&1 == :labels_broken)),
        do: send_resp(conn, 500, ~s({"message":"boom"})),
        else: send_resp(conn, 200, "[]")
    end

    delete "/repos/:owner/:repo/issues/:num/labels/:label" do
      record(conn, {:unlabel, URI.decode(conn.path_params["label"])})
      send_resp(conn, 200, "[]")
    end

    patch "/repos/:owner/:repo/issues/:num" do
      record(conn, {:patch, conn.body_params["state"]})
      send_resp(conn, 200, "{}")
    end

    match _ do
      send_resp(conn, 404, "{}")
    end

    defp record(conn, call) do
      Agent.update(:fake_github_calls, &[{conn.path_params["num"], call} | &1])
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: :fake_github_calls)
    port = 40_000 + :rand.uniform(20_000)
    {:ok, _} = Plug.Cowboy.http(FakeGitHub, [], port: port, ref: :"fake_gh_#{port}")
    Application.put_env(:gitf, :github_api_base, "http://127.0.0.1:#{port}")
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token")

    on_exit(fn ->
      Plug.Cowboy.shutdown(:"fake_gh_#{port}")
      Application.delete_env(:gitf, :github_api_base)

      if prev_token,
        do: System.put_env("GITHUB_TOKEN", prev_token),
        else: System.delete_env("GITHUB_TOKEN")
    end)

    {:ok, sector} =
      GiTF.Archive.insert(:sectors, %{
        name: "cora",
        path: "/tmp/x",
        github_owner: "mpurdon",
        github_repo: "cora"
      })

    {:ok, mission} =
      GiTF.Archive.insert(:missions, %{
        name: "m",
        sector_id: sector.id,
        source: "github_issue",
        source_issue: %{number: 23, repo: "mpurdon/cora", key: "mpurdon/cora#23"}
      })

    %{mission: mission}
  end

  defp calls,
    do:
      :fake_github_calls
      |> Agent.get(& &1)
      |> Enum.reject(&(&1 == :labels_broken))
      |> Enum.reverse()

  defp reported(mission) do
    GiTF.EventStore.replay(mission.id, types: [:reported_back])
    |> Enum.map(&{&1.data.action, &1.data.detail, &1.data.ok})
  end

  test "a merge comments, swaps the label and closes — and every act is on the timeline", %{
    mission: m
  } do
    :ok = Lifecycle.on_merged(m)

    assert calls() == [
             {"23",
              {:comment,
               "Merged — closing this issue.\n\n_— posted by the GiTF Dark Factory (Aramaki)_"}},
             {"23", {:unlabel, "gitf:in-progress"}},
             {"23", {:unlabel, "gitf:in-review"}},
             {"23", {:label, "gitf:done"}},
             {"23", {:patch, "closed"}}
           ]

    assert reported(m) == [
             {"commented", "Merged — closing this issue.", true},
             {"unlabelled", "gitf:in-progress", true},
             {"unlabelled", "gitf:in-review", true},
             {"labelled", "gitf:done", true},
             {"closed", nil, true}
           ]
  end

  test "publishing a PR moves the issue from in-progress to in-review without closing it", %{
    mission: m
  } do
    :ok = Lifecycle.on_published(m, "https://github.com/mpurdon/cora/pull/24")

    assert [
             {"unlabelled", "gitf:in-progress", true},
             {"labelled", "gitf:in-review", true},
             {"commented", text, true}
           ] =
             reported(m)

    assert text =~ "pull/24"
    refute Enum.any?(calls(), &match?({_, {:patch, _}}, &1))
  end

  test "a failed act is recorded as failed, and the rest still run", %{mission: m} do
    Agent.update(:fake_github_calls, &[:labels_broken | &1])
    :ok = Lifecycle.on_merged(m)

    assert [
             {"commented", _, true},
             {"unlabelled", _, true},
             {"unlabelled", _, true},
             {"labelled", "gitf:done", false},
             {"closed", nil, true}
           ] = reported(m)

    assert Enum.any?(calls(), &match?({_, {:patch, "closed"}}, &1))
  end
end
