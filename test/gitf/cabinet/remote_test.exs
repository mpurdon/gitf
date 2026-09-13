defmodule GiTF.Cabinet.RemoteTest do
  @moduledoc """
  The Cabinet reads a factory it usually cannot reach.

  The property worth asserting is the one that costs money if it is wrong: a
  ministry whose box is stopped must be answered from what the Cabinet already
  knows, without a request — never by waiting out a connect, and never by
  waking anything.
  """
  use GiTF.StoreCase

  alias GiTF.Cabinet.{Registry, Remote}

  defp ministry!(attrs) do
    {:ok, m} =
      Registry.create(
        Map.merge(
          %{slug: "m-#{:erlang.unique_integer([:positive])}", name: "M"},
          attrs
        )
      )

    m
  end

  describe "asleep is an answer" do
    test "a stopped box is refused instantly, with no request and no wake" do
      m = ministry!(%{url: "https://nowhere.invalid", instance_id: "i-1"})
      {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "stopped"}))

      # If this made a request it would take the full connect timeout to a host
      # that does not resolve; the point is that it does not make one.
      {elapsed_us, result} = :timer.tc(fn -> Remote.get(m.slug, "/sectors") end)

      assert result == {:error, :asleep}
      assert elapsed_us < 500_000, "an instance state we already hold is not worth a round trip"
    end

    test "browse refuses the same way, rather than firing three doomed requests" do
      m = ministry!(%{url: "https://nowhere.invalid", instance_id: "i-1"})
      {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "stopped"}))

      {elapsed_us, result} = :timer.tc(fn -> Remote.browse(m.slug) end)

      assert result == {:error, :asleep}
      assert elapsed_us < 500_000
    end

    test "not knowing the state is a reason to ask, not a reason to say asleep" do
      # A ministry the Cabinet has never observed has no :box at all. Claiming
      # it is asleep would be a guess presented as a fact.
      m = ministry!(%{url: "https://127.0.0.1:1", instance_id: "i-1"})

      refute Remote.get(m.slug, "/sectors", timeout_ms: 200) == {:error, :asleep}
    end
  end

  describe "refusals that are not about sleep" do
    test "an unregistered ministry says so" do
      assert Remote.get("no-such-ministry", "/sectors") == {:error, :unknown_ministry}
      assert Remote.browse("no-such-ministry") == {:error, :unknown_ministry}
    end

    test "a ministry with no URL says that instead of failing obscurely" do
      m = ministry!(%{instance_id: "i-1"})
      {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "running"}))

      assert Remote.get(m.slug, "/sectors") == {:error, :no_url}
    end

    test "an unreachable factory is an error, not an empty list" do
      m = ministry!(%{url: "http://127.0.0.1:1", instance_id: "i-1"})
      {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "running"}))

      assert {:error, _} = Remote.get(m.slug, "/sectors", timeout_ms: 300)
    end

    test "browse degrades to partial rather than losing everything to one failure" do
      m = ministry!(%{url: "http://127.0.0.1:1", instance_id: "i-1"})
      {:ok, _} = Registry.update(m.id, &Map.put(&1, :box, %{state: "running"}))

      assert {:ok, contents} = Remote.browse(m.slug)
      assert contents.sectors == []
      assert contents.partial?, "and it has to admit that it is partial"
    end
  end
end
