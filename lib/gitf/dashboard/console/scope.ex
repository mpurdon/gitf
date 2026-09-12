defmodule GiTF.Dashboard.Console.Scope do
  @moduledoc """
  Where the operator is, as a value.

  The Cabinet Console kept its view and selection in socket assigns alone, so
  nothing was deep-linkable: no back button, no bookmark, no link you could
  paste to someone. Scope lives in the URL here, which makes every object
  addressable and makes the tree, the crumbs and the workspace three readings
  of one fact rather than three pieces of state that can disagree.

  Paths, all under the console's mount point:

      /                       the Cabinet itself
      /activity               the fleet's event log
      /m/<slug>               one ministry
      /m/<slug>/ruleset       its activation ruleset
      /m/<slug>/registration  its registry record

  The depth tab (`overview` / `evidence` / `raw`) is a query parameter rather
  than a path segment: it is a lens on the object, not a different object, and
  it should survive when you change objects.
  """

  @enforce_keys [:level]
  defstruct level: :cabinet, ministry: nil, tab: "overview"

  @type level :: :cabinet | :activity | :ministry | :ruleset | :registration
  @type t :: %__MODULE__{level: level(), ministry: String.t() | nil, tab: String.t()}

  @tabs ~w(overview evidence raw)
  @ministry_children %{"ruleset" => :ruleset, "registration" => :registration}

  @doc "The console's mount point. Every path this module emits is prefixed with it."
  @spec root() :: String.t()
  def root, do: "/console"

  @doc """
  Parses LiveView's `params` into a scope.

  Anything unrecognised resolves to the Cabinet rather than raising: a stale
  bookmark should land you somewhere useful, not on an error.
  """
  @spec from_params(map()) :: t()
  def from_params(params) do
    tab = tab_from(params)

    case Map.get(params, "path") || [] do
      [] -> %__MODULE__{level: :cabinet, tab: tab}
      ["activity"] -> %__MODULE__{level: :activity, tab: tab}
      ["m", slug] -> %__MODULE__{level: :ministry, ministry: slug, tab: tab}
      ["m", slug, child] -> ministry_child(slug, child, tab)
      _ -> %__MODULE__{level: :cabinet, tab: tab}
    end
  end

  defp ministry_child(slug, child, tab) do
    case Map.fetch(@ministry_children, child) do
      {:ok, level} -> %__MODULE__{level: level, ministry: slug, tab: tab}
      :error -> %__MODULE__{level: :ministry, ministry: slug, tab: tab}
    end
  end

  defp tab_from(params) do
    case Map.get(params, "t") do
      t when t in @tabs -> t
      _ -> "overview"
    end
  end

  @doc "The path for a scope. Round-trips with `from_params/1`."
  @spec to_path(t()) :: String.t()
  def to_path(%__MODULE__{} = scope), do: root() <> segments(scope) <> query(scope)

  defp segments(%{level: :cabinet}), do: ""
  defp segments(%{level: :activity}), do: "/activity"
  defp segments(%{level: :ministry, ministry: slug}), do: "/m/#{slug}"
  defp segments(%{level: :ruleset, ministry: slug}), do: "/m/#{slug}/ruleset"
  defp segments(%{level: :registration, ministry: slug}), do: "/m/#{slug}/registration"

  defp query(%{tab: "overview"}), do: ""
  defp query(%{tab: tab}), do: "?t=#{tab}"

  @doc "The path for a level, reusing the ministry already in scope when the level needs one."
  @spec path(t(), level(), keyword()) :: String.t()
  def path(%__MODULE__{} = scope, level, opts \\ []) do
    ministry = Keyword.get(opts, :ministry, scope.ministry)
    tab = Keyword.get(opts, :tab, "overview")
    to_path(%__MODULE__{level: level, ministry: ministry, tab: tab})
  end

  @doc "The same object at a different depth."
  @spec with_tab(t(), String.t()) :: t()
  def with_tab(%__MODULE__{} = scope, tab) when tab in @tabs, do: %{scope | tab: tab}
  def with_tab(%__MODULE__{} = scope, _), do: scope

  @doc "Which tabs this object offers. Not every object has three depths worth having."
  @spec tabs(t()) :: [{String.t(), String.t()}]
  def tabs(%__MODULE__{level: :activity}), do: [{"overview", "Log"}]

  def tabs(%__MODULE__{level: :ruleset}),
    do: [{"overview", "Rules & coverage"}, {"evidence", "What it decided"}, {"raw", "Raw JDM"}]

  def tabs(%__MODULE__{level: :registration}), do: [{"overview", "Record"}, {"raw", "Raw"}]

  def tabs(%__MODULE__{}),
    do: [{"overview", "Overview"}, {"evidence", "Evidence"}, {"raw", "Raw"}]

  @doc """
  The crumb trail: every ancestor of the current scope, each with the path
  that returns to it. The last entry is the scope itself.
  """
  @spec crumbs(t(), (String.t() -> String.t() | nil)) :: [{String.t(), String.t()}]
  def crumbs(%__MODULE__{} = scope, name_for \\ fn slug -> slug end) do
    cabinet = {"Cabinet", path(scope, :cabinet)}

    case scope.level do
      :cabinet ->
        [cabinet]

      :activity ->
        [cabinet, {"Activity", path(scope, :activity)}]

      level ->
        ministry = {name_for.(scope.ministry) || scope.ministry, path(scope, :ministry)}

        case level do
          :ministry -> [cabinet, ministry]
          :ruleset -> [cabinet, ministry, {"Activation ruleset", path(scope, :ruleset)}]
          :registration -> [cabinet, ministry, {"Registration", path(scope, :registration)}]
        end
    end
  end

  @doc "The ministry whose subtree should be open: the one in scope, if any."
  @spec expanded(t()) :: MapSet.t()
  def expanded(%__MODULE__{ministry: nil}), do: MapSet.new()
  def expanded(%__MODULE__{ministry: slug}), do: MapSet.new([slug])
end
