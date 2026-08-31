defmodule GiTF.Cabinet.GateTest do
  use GiTF.StoreCase

  alias GiTF.Cabinet.{Gate, Registry}

  defp ministry!(attrs \\ %{}) do
    {:ok, m} =
      Registry.create(
        Map.merge(
          %{slug: "min-#{:erlang.unique_integer([:positive])}", name: "Test", url: nil},
          attrs
        )
      )

    m
  end

  defp bug_payload,
    do: %{
      "action" => "opened",
      "issue" => %{"number" => 7, "title" => "crash on save", "labels" => []}
    }

  test "a bug in normal mode wakes (records a waking inbox entry)" do
    m = ministry!()

    assert {:wake, entry} =
             Gate.handle(m, "issues", bug_payload(), %{"body" => "{}", "headers" => []})

    assert entry.class == "bug"
    # no instance_id and no url → the background forward fails safely and
    # marks the entry rather than crashing anything
  end

  test "a feature queues and shows in the inbox" do
    m = ministry!()

    payload = %{
      "action" => "opened",
      "issue" => %{"number" => 8, "title" => "Add dark mode", "labels" => []}
    }

    assert {:queue, entry} = Gate.handle(m, "issues", payload, %{})
    assert entry.status == "queued"
    assert Enum.any?(Gate.inbox(m.slug), &(&1.id == entry.id))
  end

  test "off mode queues even bugs" do
    m = ministry!(%{mode: "off"})
    assert {:queue, _} = Gate.handle(m, "issues", bug_payload(), %{})
  end

  test "over the cost cap, a bug queues instead of waking" do
    m = ministry!(%{cost_cap_usd: 100.0})
    {:ok, m} = Registry.update(m.id, &Map.put(&1, :spend_month_usd, 150.0))
    assert Gate.decide(m, :bug) == "queue"
  end

  test "noise drops without an inbox entry" do
    m = ministry!()
    before = length(Gate.inbox(m.slug))
    assert {:drop, :noise} = Gate.handle(m, "push", %{}, %{})
    assert length(Gate.inbox(m.slug)) == before
  end

  test "broken rules queue — never wake" do
    m = ministry!(%{rules: %{"nodes" => [%{"type" => "functionNode"}]}})
    assert Gate.decide(m, :bug) == "queue"
  end

  test "modes are validated" do
    m = ministry!()
    assert {:ok, %{mode: "vacation"}} = Registry.set_mode(m.id, "vacation")
    assert {:error, {:invalid, _}} = Registry.set_mode(m.id, "party")
  end

  test "slugs are validated and unique" do
    assert {:error, {:invalid, _}} = Registry.create(%{slug: "Bad Slug", name: "x"})
    {:ok, _} = Registry.create(%{slug: "twice", name: "x"})
    assert {:error, {:invalid, _}} = Registry.create(%{slug: "twice", name: "y"})
  end
end
