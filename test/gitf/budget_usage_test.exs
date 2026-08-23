defmodule GiTF.BudgetUsageTest do
  @moduledoc """
  A flat-rate subscription has no marginal cost, so a dollar cap on it is a
  fabricated number. Pricing Max usage at API list rates produced "spent
  $605.25 of $150.00" for work that cost nothing, and blocked a real change
  request. Subscription streams ration REQUESTS in a rolling window; metered
  streams still ration dollars.
  """
  use GiTF.StoreCase

  alias GiTF.Budget

  setup do
    prev = Application.get_env(:gitf, :config_provider_overrides)
    on_exit(fn -> Application.put_env(:gitf, :config_provider_overrides, prev) end)
    :ok
  end

  defp book(model, n, opts \\ []) do
    age = Keyword.get(opts, :hours_ago, 0)
    at = DateTime.utc_now() |> DateTime.add(-age * 3600, :second) |> DateTime.truncate(:second)

    for _ <- 1..n do
      GiTF.Archive.insert(:costs, %{
        model: model,
        cost_usd: 1.0,
        input_tokens: 100,
        output_tokens: 100,
        inserted_at: at
      })
    end
  end

  test "the CLI stream is a subscription; bedrock is metered" do
    assert Budget.subscription?("cli")
    refute Budget.subscription?("bedrock")
    refute Budget.subscription?("google")
  end

  test "counts requests in the window, not dollars" do
    book("claude-haiku-4-5", 5)

    usage = Budget.usage_in_window("cli")
    assert usage.requests == 5
    assert usage.tokens == 5 * 200
  end

  test "usage outside the rolling window does not count" do
    # The old dollar cap was a 24h total, so yesterday's subscription usage
    # throttled today's work. A rolling window is what the plan meters.
    book("claude-haiku-4-5", 3, hours_ago: 0)
    book("claude-haiku-4-5", 40, hours_ago: 48)

    assert Budget.usage_in_window("cli").requests == 3
  end

  test "another provider's bookings do not count against the subscription" do
    book("bedrock:anthropic.claude-sonnet-4-6", 10)
    assert Budget.usage_in_window("cli").requests == 0
  end

  test "the failure message is stated in the right unit" do
    # limit_description/1 reads the ambient execution mode, so pin it.
    prev = System.get_env("GITF_EXECUTION_MODE")
    System.put_env("GITF_EXECUTION_MODE", "cli")

    try do
      msg = Budget.limit_description(42)
      assert msg =~ "42 of"
      assert msg =~ "requests"
      # Never dollars for a subscription — that was the whole bug.
      refute msg =~ "$"
    after
      if prev,
        do: System.put_env("GITF_EXECUTION_MODE", prev),
        else: System.delete_env("GITF_EXECUTION_MODE")
    end
  end

  test "limits are runaway guards, generous by default" do
    # Explicitly NOT a mirror of the provider's real limits, which we cannot
    # observe. A few hundred calls in an hour is normal factory work.
    assert Budget.request_limit("cli") >= 1_000
    assert Budget.window_hours("cli") > 0
    # 0 disables the token check by default; requests are the real unit.
    assert Budget.token_limit("cli") == 0
  end
end
