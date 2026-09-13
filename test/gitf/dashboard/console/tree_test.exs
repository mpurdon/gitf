defmodule GiTF.Dashboard.Console.TreeTest do
  @moduledoc """
  The tree is the console's only navigation, so its shape is worth asserting
  directly: what is a child of what, what opens, and — the point of the
  redesign — that a ministry's configuration is not listed as a sibling of the
  repositories it works on.
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.Console.{Scope, Tree}

  @ha %{
    slug: "home-affairs",
    name: "Home Affairs",
    state: "running",
    state_since: "42m",
    instance_id: "i-0593ef62313cab7a1",
    mode: "normal",
    cost_cap_usd: nil,
    ruleset_version: 3
  }

  @tj %{slug: "trajector", name: "Trajector", state: nil, instance_id: nil}

  # What the factory answered. Sectors, missions and ops live on the box, so
  # they reach the tree as a separate fact from the registry record.
  @depth %{
    "home-affairs" => %{
      sectors: [%{id: "cora", name: "cora"}, %{id: "hf", name: "hello-factory"}],
      missions: [
        %{id: "msn-1", name: "six-level-priority", status: "running", sector_id: "cora"},
        %{id: "msn-2", name: "dark mode", status: "completed", sector_id: "cora"}
      ],
      ops: [
        %{id: "op-1", title: "plan it", status: "done", mission_id: "msn-1"},
        %{id: "op-2", title: "build it", status: "running", mission_id: "msn-1"},
        %{id: "op-9", title: "elsewhere", status: "done", mission_id: "msn-2"}
      ]
    }
  }

  defp ids(nodes), do: Enum.map(nodes, & &1.id)
  defp find(nodes, id), do: Enum.find(nodes, &(&1.id == id))

  defp labels_at(nodes, depth),
    do: nodes |> Enum.filter(&(&1.depth == depth)) |> Enum.map(& &1.label)

  test "a collapsed fleet lists the ministries and nothing beneath them" do
    nodes = Tree.build([@ha, @tj], %Scope{level: :cabinet}, %{activations: 19})

    assert ids(nodes) == ["cabinet", "activity", "ministry:home-affairs", "ministry:trajector"]
    assert find(nodes, "cabinet").tail == "19 activations"
  end

  test "the ministry in scope is the one that opens" do
    nodes =
      Tree.build([@ha, @tj], %Scope{level: :ministry, ministry: "home-affairs"}, %{}, @depth)

    assert "sector:home-affairs:cora" in ids(nodes)
    refute Enum.any?(ids(nodes), &String.starts_with?(&1, "sector:trajector"))
  end

  test "sectors and configuration are separated, each under its own heading" do
    nodes = Tree.build([@ha], %Scope{level: :ruleset, ministry: "home-affairs"}, %{}, @depth)
    groups = Enum.filter(nodes, &(&1.kind == :group))

    assert Enum.map(groups, & &1.label) == ["Sectors", "Configuration"]
    assert Enum.all?(groups, &is_nil(&1.path)), "a heading is not a destination"

    order = ids(nodes)
    sectors_at = Enum.find_index(order, &(&1 == "sectors:home-affairs"))
    config_at = Enum.find_index(order, &(&1 == "config:home-affairs"))
    cora_at = Enum.find_index(order, &(&1 == "sector:home-affairs:cora"))
    ruleset_at = Enum.find_index(order, &(&1 == "ruleset:home-affairs"))

    assert sectors_at < cora_at and cora_at < config_at and config_at < ruleset_at,
           "a repository and a policy must not read as the same kind of child"
  end

  test "configuration is the same four things for every ministry" do
    nodes =
      Tree.build([@ha], %Scope{level: :ministry, ministry: "home-affairs"}, %{}, @depth)

    assert labels_at(nodes, 2) |> Enum.filter(&(&1 in ~w(Mode Budget Registration))) ==
             ~w(Mode Budget Registration)

    assert find(nodes, "ruleset:home-affairs").tail == "v3"
    assert find(nodes, "budget:home-affairs").tail == "no cap"
    assert find(nodes, "budget:home-affairs").tail_tone == :warn
  end

  test "an unprovisioned ministry says so and points at what would fix it" do
    nodes = Tree.build([@tj], %Scope{level: :ministry, ministry: "trajector"})
    hint = find(nodes, "no-factory:trajector")

    assert hint.label == "no factory yet"
    assert hint.path == "/console/m/trajector/registration"
    refute Enum.any?(nodes, &(&1.label == "Sectors"))
    assert find(nodes, "registration:trajector").tail == "incomplete"
  end

  test "exactly one node is current, and it is the one in scope" do
    for scope <- [
          %Scope{level: :cabinet},
          %Scope{level: :activity},
          %Scope{level: :ministry, ministry: "home-affairs"},
          %Scope{level: :ruleset, ministry: "home-affairs"},
          %Scope{level: :registration, ministry: "home-affairs"}
        ] do
      current = Tree.build([@ha, @tj], scope) |> Enum.filter(& &1.current?)
      assert length(current) == 1, "#{scope.level}: #{length(current)} current nodes"
    end
  end

  test "every navigable node's path parses back to a scope" do
    nodes = Tree.build([@ha, @tj], %Scope{level: :ministry, ministry: "home-affairs"})

    for %{path: path, label: label} <- nodes, is_binary(path) do
      segments =
        path
        |> URI.parse()
        |> Map.get(:path)
        |> String.replace_prefix(Scope.root(), "")
        |> String.split("/", trim: true)

      assert %Scope{} = Scope.from_params(%{"path" => segments}),
             "#{label} links to #{path}, which does not resolve"
    end
  end

  test "a draft ruleset is visible from the rail without opening it" do
    nodes =
      Tree.build([Map.put(@ha, :ruleset_draft, true)], %Scope{
        level: :ministry,
        ministry: "home-affairs"
      })

    assert find(nodes, "ruleset:home-affairs").tail == "draft"
  end

  test "the activity node carries what wants a person" do
    quiet = Tree.build([], %Scope{level: :cabinet}, %{needs: 0, events: 26})
    busy = Tree.build([], %Scope{level: :cabinet}, %{needs: 4, events: 26})

    assert find(quiet, "activity").tail == "26"
    assert find(quiet, "activity").tone == nil
    assert find(busy, "activity").tail == "4 need you"
    assert find(busy, "activity").tone == :warn
  end

  describe "depth belongs to the factory" do
    defp ha_nodes(scope, depth), do: Tree.build([@ha], scope, %{}, depth)
    defp in_scope, do: %Scope{level: :ministry, ministry: "home-affairs"}

    test "the four reasons a ministry lists no sectors read differently" do
      asleep = ha_nodes(in_scope(), %{"home-affairs" => {:error, :asleep}})
      assert find(asleep, "wake:home-affairs").label =~ "asleep"

      assert find(asleep, "wake:home-affairs").path == "/console/wake/home-affairs",
             "the row that states the fact has to offer the wake, not perform it"

      # Not asked yet, and asked-but-unanswered, are the same to an operator.
      for depth <- [%{}, %{"home-affairs" => :loading}] do
        assert find(ha_nodes(in_scope(), depth), "sectors-loading:home-affairs").label =~
                 "asking the factory"
      end

      empty = ha_nodes(in_scope(), %{"home-affairs" => %{sectors: []}})
      assert find(empty, "sectors-none:home-affairs").label == "none yet"

      broken = ha_nodes(in_scope(), %{"home-affairs" => {:error, {:status, 502}}})
      assert find(broken, "sectors-error:home-affairs").label =~ "HTTP 502"
      assert find(broken, "sectors-error:home-affairs").tone == :crit

      never = Tree.build([@tj], %Scope{level: :ministry, ministry: "trajector"}, %{}, %{})
      assert find(never, "no-factory:trajector").label == "no factory yet"
    end

    test "expanding a ministry never wakes it" do
      # Every node the asleep subtree offers is a link the operator chooses to
      # follow. A tree that fetched on expand would spend a minute and a bill
      # on a click that meant "show me what you already know".
      nodes = ha_nodes(in_scope(), %{"home-affairs" => {:error, :asleep}})

      for n <- nodes, n.path do
        assert String.starts_with?(n.path, "/console"),
               "a tree node is a destination, never an action"
      end
    end

    test "missions hang off their own sector, and only the open mission lists ops" do
      nodes = ha_nodes(in_scope(), @depth)

      assert find(nodes, "sector:home-affairs:cora").tail == "2 missions"
      assert find(nodes, "mission:home-affairs:msn-1").depth == 3

      refute Enum.any?(ids(nodes), &String.starts_with?(&1, "op:")),
             "no mission is open, so no ops are listed"

      open = ha_nodes(%Scope{level: :mission, ministry: "home-affairs", id: "msn-1"}, @depth)

      assert "op:home-affairs:op-1" in ids(open)
      assert find(open, "op:home-affairs:op-1").depth == 4

      refute "op:home-affairs:op-9" in ids(open),
             "op-9 belongs to the other mission; expanding everything is how a rail stops being usable"
    end

    test "an op in scope keeps its mission open above it" do
      nodes = ha_nodes(%Scope{level: :op, ministry: "home-affairs", id: "op-2"}, @depth)

      assert "mission:home-affairs:msn-1" in ids(nodes)
      assert find(nodes, "op:home-affairs:op-2").current?
      refute find(nodes, "mission:home-affairs:msn-1").current?
    end

    test "status carries a tone, so the rail reads at a glance" do
      nodes = ha_nodes(%Scope{level: :mission, ministry: "home-affairs", id: "msn-1"}, @depth)

      assert find(nodes, "mission:home-affairs:msn-1").tail_tone == :recon
      assert find(nodes, "mission:home-affairs:msn-2").tail_tone == :ok
      assert find(nodes, "op:home-affairs:op-1").tail_tone == :ok
    end

    test "a sector with no missions says nothing rather than \"0 missions\"" do
      nodes = ha_nodes(in_scope(), %{"home-affairs" => %{sectors: [%{id: "hf", name: "hf"}]}})
      assert find(nodes, "sector:home-affairs:hf").tail == nil
    end
  end
end
