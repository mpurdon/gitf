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

  ## Depth belongs to the factory

  Sectors, missions and ops live on the ministry's box, and that box is asleep
  most of the time. So the tree describes the four states honestly rather than
  collapsing them into an empty list: **never provisioned**, **asleep**,
  **being fetched**, and **awake with nothing in it**. Asleep is not an error
  and not an absence — it is a fact with a price attached, and the row that
  states it offers the wake rather than performing it.
  """

  alias GiTF.Dashboard.Console.{Format, Scope}

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

  `depth` carries what the factory answered, keyed by ministry slug:
  `%{"home-affairs" => %{sectors: [...], missions: [...], ops: [...]}}`, or
  `:loading`, or `{:error, reason}`. A slug that is absent has not been asked.
  """
  @spec build([map()], Scope.t(), map(), map()) :: [node_t()]
  def build(ministries, %Scope{} = scope, counts \\ %{}, depth \\ %{}) do
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
    ] ++ Enum.flat_map(ministries, &ministry_nodes(&1, scope, expanded, depth))
  end

  defp ministry_nodes(m, scope, expanded, depth) do
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

    [head | if(open?, do: children(m, scope, slug, Map.get(depth, slug)), else: [])]
  end

  # Four different reasons a ministry lists no sectors, and they are not the
  # same thing to an operator: it was never provisioned; its factory is asleep;
  # the Cabinet is still asking; or it is awake and genuinely has none. The
  # Cabinet holds no mission state by design — saying "no factory yet" about a
  # registered, sleeping factory is simply false.
  defp children(m, scope, slug, depth) do
    sector_part(m, scope, slug, depth) ++
      [group("config:#{slug}", "Configuration", 2) | config_nodes(m, scope, slug)]
  end

  defp sector_part(m, scope, slug, _depth) when not is_map_key(m, :instance_id) do
    unprovisioned(scope, slug)
  end

  defp sector_part(%{instance_id: nil}, scope, slug, _depth), do: unprovisioned(scope, slug)

  defp sector_part(_m, _scope, slug, %{sectors: []}) do
    [
      group("sectors:#{slug}", "Sectors", 2),
      hint_node("sectors-none:#{slug}", "none yet", nil)
    ]
  end

  defp sector_part(_m, scope, slug, %{sectors: sectors} = d) do
    [
      group("sectors:#{slug}", "Sectors", 2)
      | Enum.flat_map(sectors, &sector_nodes(&1, scope, slug, d))
    ]
  end

  defp sector_part(_m, _scope, slug, :loading) do
    [
      group("sectors:#{slug}", "Sectors", 2),
      hint_node("sectors-loading:#{slug}", "asking the factory\u2026", :recon)
    ]
  end

  defp sector_part(_m, scope, slug, {:error, :asleep}) do
    [
      group("sectors:#{slug}", "Sectors", 2),
      # The row states the fact and offers the wake. Expanding a tree must never
      # start an instance: that is a minute and a bill, and it is the operator's
      # call to make.
      node("wake:#{slug}", :wake, "asleep \u2014 wake to browse", 2,
        path: Scope.path(scope, :wake, ministry: slug),
        tail_tone: :muted
      )
    ]
  end

  defp sector_part(_m, _scope, slug, {:error, reason}) do
    [
      group("sectors:#{slug}", "Sectors", 2),
      hint_node("sectors-error:#{slug}", "could not reach it: #{Format.reason(reason)}", :crit)
    ]
  end

  # Nothing known yet — not asked, or asked and the answer has not landed.
  defp sector_part(_m, _scope, slug, _unasked) do
    [
      group("sectors:#{slug}", "Sectors", 2),
      hint_node("sectors-loading:#{slug}", "asking the factory\u2026", :recon)
    ]
  end

  defp unprovisioned(scope, slug) do
    [
      node("no-factory:#{slug}", :hint, "no factory yet", 2,
        path: Scope.path(scope, :registration, ministry: slug)
      )
    ]
  end

  defp hint_node(id, label, tone),
    do: node(id, :hint, label, 2, path: nil, tone: tone)

  # A sector, then the missions that belong to it, then the ops of whichever
  # mission is in scope. Only one mission's ops are ever listed: a rail that
  # expands everything is a rail nobody can find anything in.
  defp sector_nodes(sector, scope, slug, depth) do
    id = to_string(sector[:id] || sector[:name])
    missions = Enum.filter(depth[:missions] || [], &(to_string(&1[:sector_id]) == id))
    open = open_mission(scope, slug, depth)

    head =
      node("sector:#{slug}:#{id}", :sector, sector[:name] || id, 2,
        path: Scope.path(scope, :sector, ministry: slug, id: id),
        tail: mission_tail(missions),
        current?: scope.level == :sector and scope.id == id
      )

    [head | Enum.flat_map(missions, &mission_nodes(&1, scope, slug, depth, open))]
  end

  # Exactly one mission's ops are listed: the one in scope, or — when an op is
  # in scope — the mission that op belongs to, so the trail above it stays open.
  defp open_mission(%{ministry: slug, level: :mission, id: id}, slug, _depth) when is_binary(id),
    do: id

  defp open_mission(%{ministry: slug, level: :op, id: id}, slug, depth) when is_binary(id) do
    case Enum.find(List.wrap(depth[:ops]), &(to_string(&1[:id]) == id)) do
      %{mission_id: mission_id} -> to_string(mission_id)
      _ -> nil
    end
  end

  defp open_mission(_scope, _slug, _depth), do: nil

  defp mission_nodes(mission, scope, slug, depth, open) do
    id = to_string(mission[:id])
    open? = open == id

    head =
      node("mission:#{slug}:#{id}", :mission, mission[:name] || id, 3,
        path: Scope.path(scope, :mission, ministry: slug, id: id),
        tail: mission[:status],
        tail_tone: status_tone(mission[:status]),
        tone: status_tone(mission[:status]),
        twist: if(open?, do: "\u25be", else: "\u25b8"),
        current?: scope.level == :mission and scope.id == id
      )

    ops =
      if open? do
        depth[:ops]
        |> List.wrap()
        |> Enum.filter(&(to_string(&1[:mission_id]) == id))
        |> Enum.map(&op_node(&1, scope, slug))
      else
        []
      end

    [head | ops]
  end

  defp op_node(op, scope, slug) do
    id = to_string(op[:id])

    node("op:#{slug}:#{id}", :op, op[:title] || id, 4,
      path: Scope.path(scope, :op, ministry: slug, id: id),
      tail: op[:status],
      tail_tone: status_tone(op[:status]),
      current?: scope.level == :op and scope.id == id
    )
  end

  defp mission_tail([]), do: nil
  defp mission_tail([_]), do: "1 mission"
  defp mission_tail(list), do: "#{length(list)} missions"

  # One mapping for the whole Console — see `Format.work_tone/1`. A mission that
  # reads green in the rail and grey on its page is two claims about one fact.
  defp status_tone(status), do: Format.work_tone(status)

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
