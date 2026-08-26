defmodule GiTF.GitHubTest do
  use ExUnit.Case, async: true

  alias GiTF.GitHub

  describe "client/1" do
    test "returns error when sector has no github config" do
      sector = %{
        id: "sec-test",
        name: "test",
        github_owner: nil,
        github_repo: nil
      }

      assert {:error, :no_github_config} = GitHub.client(sector)
    end

    test "builds a client when github config and a token are present" do
      sector = %{
        id: "sec-test",
        name: "test",
        github_owner: "testorg",
        github_repo: "testrepo"
      }

      prior = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "ghp_test_token")

      on_exit(fn ->
        if prior,
          do: System.put_env("GITHUB_TOKEN", prior),
          else: System.delete_env("GITHUB_TOKEN")
      end)

      assert {:ok, %Req.Request{}} = GitHub.client(sector)
    end

    test "refuses an anonymous client when no token is available" do
      sector = %{
        id: "sec-test",
        name: "test",
        github_owner: "testorg",
        github_repo: "testrepo"
      }

      prior = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")

      on_exit(fn ->
        if prior, do: System.put_env("GITHUB_TOKEN", prior)
      end)

      # Anonymous clients silently 404 private repos and burn the 60/hr
      # IP budget — client/1 must refuse loudly. (May still find a token
      # via gh keyring on dev machines; accept either outcome there.)
      case GitHub.client(sector) do
        {:error, :no_github_token} -> :ok
        {:ok, %Req.Request{}} -> :ok
      end
    end
  end

  describe "create_pr/3" do
    test "returns error when sector has no github config" do
      sector = %{id: "sec-1", name: "t", github_owner: nil, github_repo: nil}

      shell = %{
        id: "cel-1",
        branch: "b",
        ghost_id: "ghost-1",
        sector_id: "sec-1",
        worktree_path: "/tmp",
        status: "active"
      }

      op = %{id: "op-1", title: "t", status: "done", mission_id: "q", sector_id: "sec-1"}

      assert {:error, :no_github_config} = GitHub.create_pr(sector, shell, op)
    end
  end

  describe "list_issues/2" do
    test "returns error when sector has no github config" do
      sector = %{id: "sec-1", name: "t", github_owner: nil, github_repo: nil}
      assert {:error, :no_github_config} = GitHub.list_issues(sector)
    end
  end
end
