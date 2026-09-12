defmodule GiTF.Dashboard.Console.Tree do
  @moduledoc """
  The fleet as one tree: Cabinet down to a ministry's configuration.

  Pure — ministries and a scope in, a flat list of nodes out — so the shape of
  the hierarchy can be tested without a browser, and so the rail, the crumbs
  and the workspace all read from the same description of where things live.

  Two kinds of child hang off a ministry and they are deliberately separated
  by a heading each: **Sectors** are what a factory works on, **Configuration**
  is how it behaves. The old console listed a ruleset as a sibling of a repo,
  which made a policy look like a piece of content.
  """

  alias GiTF.Dashboard.Console.Scope

  @type node_t :: %{
          id: String.t(),
          kind: atom(),
          label: String.t(),
          depth: non_neg_integer(),
          path: String.t() | nil,
          tail: String.t() | nil,
          tone: atom() | nil,
          tail_tone: atom() | nil,
          current?: boolean(),
          twist: String.t() | nil
        }

  @doc """
  Builds the tree.

  `counts` carries the few numbers the rail shows without a fetch of its own:
  `:activations`, `:needs`. Missing keys simply render no tail.
  """
  @spec build([map()], Scope.t(), map()) :: [node_t()]
  def build(ministries, %Scope{} = scope, counts \\ %{}) do
    expanded = Scope.expanded(scope)

    [
      node("cabinet", :cabinet, "Cabinet", 0,
        path: Scope.path(scope, :cabinet),
        tail: tail_count(counts[:activations], "activations"),
        tone: :ok,
        twist: "▾",
        current?: scope.level == :cabinet
      ),
      node("activity", :activity, "Activity", 1,
        path: Scope.path(scope, :activity),
        tail: needs_tail(counts),
        tail_tone: if(counts[:needs] && counts[:needs] > 0, do: :warn),
        tone: if(counts[:needs] && counts[:needs] > 0, do: :warn),
        current?: scope.level == :activity
      )
    ] ++ Enum.flat_map(ministries, &ministry_nodes(&1, scope, expanded))
  end

  defp ministry_nodes(m, scope, expanded) do
    slug = m.slug
    open? = MapSet.member?(expanded, slug)

    head =
      node("ministry:#{slug}", :ministry, m[:name] || slug, 1,
        path: Scope.path(scope, :ministry, ministry: slug),
        tail: state_tail(m),
        tone: state_tone(m),
        twist: if(open?, do: "▾", else: "▸"),
        current?: scope.level == :ministry and scope.ministry == slug
      )

    [head | if(open?, do: children(m, scope, slug), else: [])]
  end

  # An unprovisioned ministry has a registration and nothing else — saying so
  # is more useful than an empty branch.
  defp children(m, scope, slug) do
    sectors = m[:sectors] || []

    sector_part =
      if sectors == [] do
        [
          node("no-factory:#{slug}", :hint, "no factory yet", 2,
            path: Scope.path(scope, :registration, ministry: slug)
          )
        ]
      else
        [group("sectors:#{slug}", "Sectors", 2) | Enum.map(sectors, &sector_node(&1, slug))]
      end

    sector_part ++ [group("config:#{slug}", "Configuration", 2) | config_nodes(m, scope, slug)]
  end

  defp sector_node(sector, slug) do
    name = sector[:name] || sector["name"] || to_string(sector)

    node("sector:#{slug}:#{name}", :sector, name, 2,
      path: nil,
      tail: "asleep",
      tail_tone: :muted
    )
  end

  defp config_nodes(m, scope, slug) do
    [
      node("ruleset:#{slug}", :ruleset, "Activation ruleset", 2,
        path: Scope.path(scope, :ruleset, ministry: slug),
        tail: ruleset_tail(m),
        current?: scope.level == :ruleset and scope.ministry == slug
      ),
      node("mode:#{slug}", :mode, "Mode", 2,
        path: Scope.path(scope, :ministry, ministry: slug),
        tail: m[:mode] || "normal"
      ),
      node("budget:#{slug}", :budget, "Budget", 2,
        path: Scope.path(scope, :registration, ministry: slug),
        tail: budget_tail(m),
        tail_tone: if(is_nil(m[:cost_cap_usd]), do: :warn)
      ),
      node("registration:#{slug}", :registration, "Registration", 2,
        path: Scope.path(scope, :registration, ministry: slug),
        tail: if(m[:instance_id], do: "complete", else: "incomplete"),
        tail_tone: if(is_nil(m[:instance_id]), do: :warn),
        current?: scope.level == :registration and scope.ministry == slug
      )
    ]
  end

  defp node(id, kind, label, depth, opts) do
    %{
      id: id,
      kind: kind,
      label: label,
      depth: depth,
      path: Keyword.get(opts, :path),
      tail: Keyword.get(opts, :tail),
      tone: Keyword.get(opts, :tone),
      tail_tone: Keyword.get(opts, :tail_tone),
      current?: Keyword.get(opts, :current?, false),
      twist: Keyword.get(opts, :twist)
    }
  end

  defp group(id, label, depth),
    do: node(id, :group, label, depth, path: nil)

  defp tail_count(nil, _noun), do: nil
  defp tail_count(n, noun), do: "#{n} #{noun}"

  defp needs_tail(%{needs: n}) when is_integer(n) and n > 0, do: "#{n} need you"
  defp needs_tail(%{events: n}) when is_integer(n), do: to_string(n)
  defp needs_tail(_), do: nil

  defp state_tail(%{state: "running", state_since: since}) when is_binary(since), do: since
  defp state_tail(%{state: "running"}), do: "up"
  defp state_tail(%{state: "stopped"}), do: "asleep"
  defp state_tail(_), do: "—"

  defp state_tone(%{state: "running"}), do: :ok
  defp state_tone(%{state: "pending"}), do: :recon
  defp state_tone(%{state: "stopping"}), do: :recon
  defp state_tone(_), do: nil

  defp ruleset_tail(%{ruleset_draft: true}), do: "draft"
  defp ruleset_tail(%{ruleset_version: v}) when is_integer(v), do: "v#{v}"
  defp ruleset_tail(_), do: nil

  defp budget_tail(%{cost_cap_usd: cap}) when is_number(cap),
    do: "$#{:erlang.float_to_binary(cap / 1, decimals: 0)}"

  defp budget_tail(_), do: "no cap"
end
