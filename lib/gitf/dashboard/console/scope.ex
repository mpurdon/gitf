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
      /m/<slug>/s/<id>        one of its sectors
      /m/<slug>/msn/<id>      one mission
      /m/<slug>/op/<id>       one op
      /wake/<slug>            wake that factory and open it — the cold bookmark

  The last three live on the factory, not the Cabinet, so they are addressable
  whether or not the box is awake: the URL names the thing, and a cold link
  lands on a page that says the factory is asleep and offers to wake it. That
  is the point of putting them in the URL at all — a mission you cannot link to
  is a mission you have to navigate to.

  The depth tab (`overview` / `evidence` / `raw`) is a query parameter rather
  than a path segment: it is a lens on the object, not a different object, and
  it should survive when you change objects.
  """

  @enforce_keys [:level]
  defstruct level: :cabinet, ministry: nil, id: nil, tab: "overview"

  @type level ::
          :cabinet
          | :activity
          | :ministry
          | :ruleset
          | :registration
          | :sector
          | :mission
          | :op
          | :wake
  @type t :: %__MODULE__{
          level: level(),
          ministry: String.t() | nil,
          id: String.t() | nil,
          tab: String.t()
        }

  @tabs ~w(overview evidence raw)
  @ministry_children %{"ruleset" => :ruleset, "registration" => :registration}
  @deep_children %{"s" => :sector, "msn" => :mission, "op" => :op}

  @doc "The levels that live on the factory rather than in the Cabinet."
  @spec deep?(t()) :: boolean()
  def deep?(%__MODULE__{level: level}), do: level in [:sector, :mission, :op]

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
      ["wake", slug] -> %__MODULE__{level: :wake, ministry: slug, tab: tab}
      ["m", slug] -> %__MODULE__{level: :ministry, ministry: slug, tab: tab}
      ["m", slug, child] -> ministry_child(slug, child, tab)
      ["m", slug, child, id] -> deep_child(slug, child, id, tab)
      _ -> %__MODULE__{level: :cabinet, tab: tab}
    end
  end

  defp ministry_child(slug, child, tab) do
    case Map.fetch(@ministry_children, child) do
      {:ok, level} -> %__MODULE__{level: level, ministry: slug, tab: tab}
      :error -> %__MODULE__{level: :ministry, ministry: slug, tab: tab}
    end
  end

  defp deep_child(slug, child, id, tab) do
    case Map.fetch(@deep_children, child) do
      {:ok, level} -> %__MODULE__{level: level, ministry: slug, id: id, tab: tab}
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
  defp segments(%{level: :sector, ministry: slug, id: id}), do: "/m/#{slug}/s/#{id}"
  defp segments(%{level: :mission, ministry: slug, id: id}), do: "/m/#{slug}/msn/#{id}"
  defp segments(%{level: :op, ministry: slug, id: id}), do: "/m/#{slug}/op/#{id}"
  defp segments(%{level: :wake, ministry: slug}), do: "/wake/#{slug}"

  defp query(%{tab: "overview"}), do: ""
  defp query(%{tab: tab}), do: "?t=#{tab}"

  @doc "The path for a level, reusing the ministry already in scope when the level needs one."
  @spec path(t(), level(), keyword()) :: String.t()
  def path(%__MODULE__{} = scope, level, opts \\ []) do
    ministry = Keyword.get(opts, :ministry, scope.ministry)
    tab = Keyword.get(opts, :tab, "overview")
    id = Keyword.get(opts, :id)
    to_path(%__MODULE__{level: level, ministry: ministry, id: id, tab: tab})
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
  def tabs(%__MODULE__{level: :sector}), do: [{"overview", "Sector"}, {"raw", "Raw"}]

  def tabs(%__MODULE__{level: :mission}),
    do: [{"overview", "Mission"}, {"evidence", "Ops"}, {"raw", "Raw"}]

  def tabs(%__MODULE__{level: :op}), do: [{"overview", "Op"}, {"raw", "Raw"}]
  # :wake is an act, not a place — it redirects before a tab strip means anything.
  def tabs(%__MODULE__{level: :wake}), do: []

  def tabs(%__MODULE__{}),
    do: [{"overview", "Overview"}, {"evidence", "Evidence"}, {"raw", "Raw"}]

  @doc """
  The crumb trail: every ancestor of the current scope, each with the path
  that returns to it. The last entry is the scope itself.

  `label` names the object at a deep level — a mission's name, a sector's. It
  is optional because the trail has to render before the factory has answered,
  and an id is a worse crumb than a name but a far better one than a gap.
  """
  @spec crumbs(t(), (String.t() -> String.t() | nil), String.t() | nil) ::
          [{String.t(), String.t()}]
  def crumbs(%__MODULE__{} = scope, name_for \\ fn slug -> slug end, label \\ nil) do
    cabinet = {"Cabinet", path(scope, :cabinet)}

    case scope.level do
      :cabinet ->
        [cabinet]

      :activity ->
        [cabinet, {"Activity", path(scope, :activity)}]

      level ->
        ministry = {name_for.(scope.ministry) || scope.ministry, path(scope, :ministry)}

        deep = fn -> {label || scope.id, to_path(scope)} end

        case level do
          :ministry -> [cabinet, ministry]
          :wake -> [cabinet, ministry]
          :ruleset -> [cabinet, ministry, {"Activation ruleset", path(scope, :ruleset)}]
          :registration -> [cabinet, ministry, {"Registration", path(scope, :registration)}]
          :sector -> [cabinet, ministry, deep.()]
          :mission -> [cabinet, ministry, deep.()]
          :op -> [cabinet, ministry, deep.()]
        end
    end
  end

  @doc "The ministry whose subtree should be open: the one in scope, if any."
  @spec expanded(t()) :: MapSet.t()
  def expanded(%__MODULE__{ministry: nil}), do: MapSet.new()
  def expanded(%__MODULE__{ministry: slug}), do: MapSet.new([slug])
end
