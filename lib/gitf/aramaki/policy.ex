defmodule GiTF.Aramaki.Policy do
  @moduledoc """
  Pure admission policy for Aramaki (the project-management / admission layer
  that sits above the factory).

  These functions decide *whether* and *when* a piece of incoming work becomes
  an active mission. Kept pure (no Archive writes, no side effects) so the
  decisions are testable and the GenServer owns the effects.

  Two gates matter most:

    * **Trigger label** (`admit_issue?/2`) — the untrusted-input safety gate.
      An issue body is attacker-controllable on public repos, and admitted
      work runs as ghosts with real tool access. So only issues carrying an
      explicit maintainer-applied label (default `gitf:build`) are admitted.
    * **Capacity** (`capacity_available?/1`) — never admit past the factory
      daily budget ceiling or the concurrent-mission cap; admission is a
      multiplier on every runaway risk.
  """

  @default_trigger_label "gitf:build"
  @default_max_concurrent 5

  @doc "The label that opts an issue into the factory (config `[:aramaki, :trigger_label]`)."
  @spec trigger_label() :: String.t()
  def trigger_label do
    Application.get_env(:gitf, :aramaki, [])
    |> Keyword.get(:trigger_label, @default_trigger_label)
  end

  @doc "Max missions Aramaki keeps in flight at once (config `[:aramaki, :max_concurrent]`)."
  @spec max_concurrent() :: pos_integer()
  def max_concurrent do
    Application.get_env(:gitf, :aramaki, [])
    |> Keyword.get(:max_concurrent, @default_max_concurrent)
  end

  @doc """
  Should this pull-request review be admitted?

  The capacity gate is shared with issues via `capacity_available?/1` — this
  covers only what is specific to a review. There is no label equivalent: a
  review can only be left by someone with access to the repository, so the
  untrusted-input problem that makes `gitf:build` necessary for issues does
  not arise. What does arise is looping, since the factory can comment on
  its own pull requests.

  `review` is the webhook/poller review object; `opts` may carry `:bot_login`.
  Returns `:admit` or `{:reject, reason}`.
  """
  @spec admit_review?(map(), keyword()) :: :admit | {:reject, atom()}
  def admit_review?(review, opts \\ []) do
    author = review_author(review)
    bot_login = Keyword.get(opts, :bot_login)

    cond do
      not changes_requested?(review) -> {:reject, :not_changes_requested}
      bot_login && author && author == bot_login -> {:reject, :own_activity}
      true -> :admit
    end
  end

  defp changes_requested?(review) do
    review
    |> Map.get("state", Map.get(review, :state))
    |> to_string()
    |> String.downcase()
    |> Kernel.==("changes_requested")
  end

  defp review_author(review) do
    case Map.get(review, "user") || Map.get(review, :user) do
      %{"login" => login} -> login
      _ -> Map.get(review, "author") || Map.get(review, :author)
    end
  end

  @doc """
  Should this GitHub issue be admitted? `issue` is the webhook payload's
  `"issue"` object; `opts` may carry `:bot_login` to reject the factory's own
  activity (loop prevention).

  Returns `{:admit, priority}` or `{:reject, reason}`.
  """
  @spec admit_issue?(map(), keyword()) :: {:admit, integer()} | {:reject, atom()}
  def admit_issue?(issue, opts \\ []) do
    labels = issue_labels(issue)
    author = get_in(issue, ["user", "login"])
    bot_login = Keyword.get(opts, :bot_login)

    cond do
      # Never act on a pull request that arrived on the issues endpoint.
      Map.has_key?(issue, "pull_request") -> {:reject, :is_pull_request}
      issue["state"] == "closed" -> {:reject, :closed}
      # Loop prevention: ignore issues the factory itself opened.
      bot_login && author == bot_login -> {:reject, :own_activity}
      trigger_label() not in labels -> {:reject, :not_labeled}
      true -> {:admit, priority(labels)}
    end
  end

  @doc """
  Lower number = higher priority. Bugs and security jump the queue ahead of
  features/chores; everything else is neutral.
  """
  @spec priority([String.t()]) :: integer()
  def priority(labels) do
    cond do
      "security" in labels -> 0
      "bug" in labels -> 1
      "feature" in labels or "enhancement" in labels -> 3
      true -> 2
    end
  end

  @doc """
  Is there capacity to admit another mission right now? Checks the factory
  daily budget ceiling and the concurrent-mission cap. `active_count` is the
  number of Aramaki missions already in flight.
  """
  @spec capacity_available?(non_neg_integer()) :: {:ok, non_neg_integer()} | {:full, atom()}
  def capacity_available?(active_count) do
    cond do
      active_count >= max_concurrent() ->
        {:full, :max_concurrent}

      match?({:error, :daily_budget_exceeded, _}, GiTF.Budget.global_check()) ->
        {:full, :daily_budget}

      true ->
        {:ok, max_concurrent() - active_count}
    end
  end

  defp issue_labels(issue) do
    (issue["labels"] || [])
    |> Enum.map(fn
      %{"name" => n} -> n
      n when is_binary(n) -> n
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
end
