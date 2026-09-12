defmodule GiTF.Dashboard.Console.ScopeTest do
  @moduledoc """
  Scope is the console's only piece of navigational state, so it has to
  round-trip: whatever the tree links to, `from_params/1` must resolve back to
  the same object. The old console kept this in socket assigns, where nothing
  could be bookmarked and the back button did nothing.
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.Console.Scope

  defp parse(path) do
    %URI{path: p, query: q} = URI.parse(path)

    segments =
      p |> String.replace_prefix(Scope.root(), "") |> String.split("/", trim: true)

    params = Map.merge(URI.decode_query(q || ""), %{"path" => segments})
    Scope.from_params(params)
  end

  test "every scope round-trips through its own path" do
    scopes = [
      %Scope{level: :cabinet},
      %Scope{level: :activity},
      %Scope{level: :ministry, ministry: "home-affairs"},
      %Scope{level: :ruleset, ministry: "home-affairs"},
      %Scope{level: :registration, ministry: "trajector"},
      %Scope{level: :ministry, ministry: "home-affairs", tab: "evidence"},
      %Scope{level: :ruleset, ministry: "home-affairs", tab: "raw"}
    ]

    for scope <- scopes do
      assert parse(Scope.to_path(scope)) == scope,
             "#{Scope.to_path(scope)} did not round-trip"
    end
  end

  test "the overview tab is the absence of a query, not ?t=overview" do
    assert Scope.to_path(%Scope{level: :ministry, ministry: "ha"}) == "/console/m/ha"

    assert Scope.to_path(%Scope{level: :ministry, ministry: "ha", tab: "raw"}) ==
             "/console/m/ha?t=raw"
  end

  test "a stale or malformed path lands on the Cabinet rather than raising" do
    for params <- [
          %{"path" => ["m"]},
          %{"path" => ["nonsense"]},
          %{"path" => ["m", "ha", "sectors", "cora"]},
          %{}
        ] do
      assert %Scope{level: :cabinet} = Scope.from_params(params)
    end
  end

  test "an unknown ministry child falls back to the ministry, keeping the slug" do
    scope = Scope.from_params(%{"path" => ["m", "home-affairs", "budget"]})
    assert scope.level == :ministry
    assert scope.ministry == "home-affairs"
  end

  test "an unknown tab is overview, so a bad link cannot render a blank pane" do
    assert Scope.from_params(%{"path" => [], "t" => "sideways"}).tab == "overview"
    assert Scope.with_tab(%Scope{level: :cabinet}, "nope").tab == "overview"
  end

  test "path/3 carries the ministry already in scope" do
    scope = %Scope{level: :ruleset, ministry: "home-affairs", tab: "raw"}
    assert Scope.path(scope, :registration) == "/console/m/home-affairs/registration"
    assert Scope.path(scope, :cabinet) == "/console"
    assert Scope.path(scope, :ministry, ministry: "trajector") == "/console/m/trajector"
  end

  test "crumbs name every ancestor and end at the object itself" do
    names = fn "home-affairs" -> "Home Affairs" end
    scope = %Scope{level: :ruleset, ministry: "home-affairs"}

    assert Scope.crumbs(scope, names) == [
             {"Cabinet", "/console"},
             {"Home Affairs", "/console/m/home-affairs"},
             {"Activation ruleset", "/console/m/home-affairs/ruleset"}
           ]

    assert Scope.crumbs(%Scope{level: :cabinet}) == [{"Cabinet", "/console"}]
  end

  test "the ministry in scope is the subtree that opens" do
    assert Scope.expanded(%Scope{level: :cabinet}) |> Enum.empty?()
    assert Scope.expanded(%Scope{level: :ruleset, ministry: "ha"}) |> MapSet.member?("ha")
  end

  test "objects offer only the depths they actually have" do
    assert Scope.tabs(%Scope{level: :activity}) == [{"overview", "Log"}]
    assert length(Scope.tabs(%Scope{level: :registration, ministry: "ha"})) == 2
    assert length(Scope.tabs(%Scope{level: :ministry, ministry: "ha"})) == 3
  end
end
