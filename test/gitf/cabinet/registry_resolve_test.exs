defmodule GiTF.Cabinet.RegistryResolveTest do
  use GiTF.StoreCase

  alias GiTF.Cabinet.Registry

  setup do
    {:ok, home} =
      Registry.create(%{slug: "home-affairs", name: "Home Affairs", url: "https://ha.example"})

    {:ok, traj} =
      Registry.create(%{slug: "trajector", name: "Trajector", url: "https://tj.example"})

    %{home: home, traj: traj}
  end

  describe "resolve/1 — the exact paths" do
    test "the slug itself", %{home: home} do
      assert {:ok, m} = Registry.resolve("home-affairs")
      assert m.id == home.id
    end

    test "the display name, in any case", %{home: home} do
      for input <- ["Home Affairs", "home affairs", "HOME AFFAIRS", "  Home Affairs  "] do
        assert {:ok, m} = Registry.resolve(input), input
        assert m.id == home.id, input
      end
    end

    test "prose that slugifies onto the slug", %{home: home} do
      # This is the case the whole function exists for: a person types
      # words, the registry holds a path-safe slug.
      for input <- ["home_affairs", "home  affairs", "Home_Affairs"] do
        assert {:ok, m} = Registry.resolve(input), input
        assert m.id == home.id, input
      end
    end
  end

  describe "resolve/1 — fuzzy" do
    test "a typo still lands", %{home: home} do
      for input <- ["home-affars", "home affair", "hom affairs"] do
        assert {:ok, m} = Registry.resolve(input), input
        assert m.id == home.id, input
      end
    end

    test "an unrelated word matches nothing" do
      for input <- ["accounts", "zzzzzz", "the treasury"] do
        assert Registry.resolve(input) == {:error, :no_match}, input
      end
    end

    test "a different ministry is not dragged in by fuzz", %{traj: traj} do
      assert {:ok, m} = Registry.resolve("trajectr")
      assert m.id == traj.id
    end
  end

  describe "resolve/1 — refusing to guess" do
    test "a near miss picks the closer ministry rather than calling it ambiguous", %{home: home} do
      {:ok, _} = Registry.create(%{slug: "home-affairs-eu", name: "Home Affairs EU", url: "u"})

      # "home affair" is genuinely nearer home-affairs than home-affairs-eu.
      # Refusing here would make the resolver useless the moment a second
      # ministry shares a prefix — ambiguity is for real ties only.
      assert {:ok, m} = Registry.resolve("home affair")
      assert m.id == home.id
    end

    test "a genuine tie comes back as candidates, not a pick" do
      # Waking the wrong box costs money and starts work nobody asked for,
      # so a tie is the caller's problem to resolve, not ours.
      {:ok, _} = Registry.create(%{slug: "ministry-a", name: "Ministry A", url: "u"})
      {:ok, _} = Registry.create(%{slug: "ministry-b", name: "Ministry B", url: "u"})

      assert {:ambiguous, candidates} = Registry.resolve("ministry-x")
      slugs = candidates |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == ["ministry-a", "ministry-b"]
    end

    test "two ministries sharing a display name are ambiguous" do
      {:ok, _} = Registry.create(%{slug: "ha-two", name: "Home Affairs", url: "u"})

      assert {:ambiguous, candidates} = Registry.resolve("Home Affairs")
      assert length(candidates) == 2
    end
  end

  describe "resolve/1 — junk in" do
    test "empty, blank and non-binary input never raise" do
      for input <- ["", "   ", nil, 42, %{}, :home_affairs] do
        assert Registry.resolve(input) == {:error, :no_match}, inspect(input)
      end
    end
  end
end
