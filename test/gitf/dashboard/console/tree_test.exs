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
    ruleset_version: 3,
    sectors: [%{name: "cora"}, %{name: "hello-factory"}]
  }

  @tj %{slug: "trajector", name: "Trajector", state: nil, sectors: []}

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
    nodes = Tree.build([@ha, @tj], %Scope{level: :ministry, ministry: "home-affairs"})

    assert "sector:home-affairs:cora" in ids(nodes)
    refute Enum.any?(ids(nodes), &String.starts_with?(&1, "sector:trajector"))
  end

  test "sectors and configuration are separated, each under its own heading" do
    nodes = Tree.build([@ha], %Scope{level: :ruleset, ministry: "home-affairs"})
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
    nodes = Tree.build([@ha], %Scope{level: :ministry, ministry: "home-affairs"})

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
end
