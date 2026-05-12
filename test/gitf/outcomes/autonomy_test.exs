defmodule GiTF.Outcomes.AutonomyTest do
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Outcomes.Autonomy

  setup do
    prior_flag = Application.get_env(:gitf, :outcome_autonomy_tiers_enabled, false)
    Application.put_env(:gitf, :outcome_autonomy_tiers_enabled, true)

    Enum.each(Archive.all(:mission_outcomes), fn o -> Archive.delete(:mission_outcomes, o.id) end)

    Archive.all(:model_reputation)
    |> Enum.filter(fn r -> is_binary(r.id) and String.contains?(r.id, ":merge") end)
    |> Enum.each(fn r -> Archive.delete(:model_reputation, r.id) end)

    Enum.each(Archive.all(:sectors), fn s ->
      if s.id in ~w(sec-trust sec-normal sec-deny) do
        Archive.delete(:sectors, s.id)
      end
    end)

    on_exit(fn -> Application.put_env(:gitf, :outcome_autonomy_tiers_enabled, prior_flag) end)
    :ok
  end

  defp seed_outcome(sector_id, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Archive.insert(:mission_outcomes, %{
      mission_id: "msn-#{:erlang.unique_integer([:positive])}",
      sector_id: sector_id,
      outcome_category: category,
      tracking_stopped: true,
      updated_at: now,
      first_tracked_at: now,
      reviews: [],
      revert_detected: false,
      changes_requested_count: 0,
      poll_count: 1
    })
  end

  describe "tier_for/1 derivation" do
    test ":insufficient_data → :normal" do
      assert %{tier: :normal, reason: :insufficient_data} = Autonomy.tier_for("sec-nothing")
    end

    test "20 samples @ 95% → :trusted" do
      for _ <- 1..19, do: seed_outcome("sec-trust", :merged_clean)
      seed_outcome("sec-trust", :merged_reverted)

      assert %{tier: :trusted, rate: r, sample_count: 20} = Autonomy.tier_for("sec-trust")
      assert r >= 0.9
    end

    test "10 samples @ 30% → :require_approval" do
      for _ <- 1..3, do: seed_outcome("sec-deny", :merged_clean)
      for _ <- 1..7, do: seed_outcome("sec-deny", :merged_reverted)

      assert %{tier: :require_approval, sample_count: 10} = Autonomy.tier_for("sec-deny")
    end

    test "below both thresholds → :normal (rate 0.7, 15 samples)" do
      for _ <- 1..10, do: seed_outcome("sec-normal", :merged_clean)
      for _ <- 1..5, do: seed_outcome("sec-normal", :merged_reverted)

      assert %{tier: :normal, reason: :within_normal_band} = Autonomy.tier_for("sec-normal")
    end

    test "feature-flag off → :normal / :feature_disabled" do
      Application.put_env(:gitf, :outcome_autonomy_tiers_enabled, false)
      for _ <- 1..20, do: seed_outcome("sec-trust", :merged_clean)

      assert %{tier: :normal, reason: :feature_disabled} = Autonomy.tier_for("sec-trust")
    end
  end

  describe "effective_tier/1 + operator override" do
    test "override beats derived tier" do
      for _ <- 1..20, do: seed_outcome("sec-trust", :merged_clean)
      {:ok, _} = Archive.insert(:sectors, %{id: "sec-trust", autonomy_level: :require_approval})

      assert Autonomy.tier("sec-trust") == :trusted
      assert Autonomy.effective_tier("sec-trust") == :require_approval
    end
  end
end
