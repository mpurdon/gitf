defmodule GiTF.Dashboard.Console.Events do
  @moduledoc """
  One stream out of the two things the Cabinet records, and the facets for
  reading it.

  The Cabinet keeps activations (`:cabinet_inbox` — a delivery and what the
  ruleset decided about it) and acts (`:cabinet_activity` — who did what to the
  fleet). They are the same story told from two sides: a bug arrives, a rule
  wakes a factory, a person holds it awake. Splitting them across two screens
  meant the record of an unattended night had to be reassembled by eye.

  ## Facets

  Counts are computed with the facet's *own* selection excluded, which is the
  only way they answer the question a person is actually asking — "what would I
  get if I also picked this?" — rather than "what did I already pick". A facet
  value with nothing behind it is shown at zero rather than hidden, so the
  absence is legible.

  There is deliberately **no sector facet**. Sectors live on the factory, not
  the Cabinet, so a sector control here could only ever be empty — and an empty
  filter reads as proof that nothing matched. That is the same mistake as the
  old `dropped` inbox filter and it is not repeated.
  """

  alias GiTF.Dashboard.Console.Scope

  # A list, not a map: this is the order the kinds are offered in, and it runs
  # from what an operator acts on to what they merely audit. A map would have
  # ordered them however the atoms happened to sort.
  @kinds [
    activation: "Activation",
    wake: "Wake",
    sleep: "Sleep",
    observation: "Observation",
    policy: "Policy change",
    registry: "Registry change",
    other: "Other"
  ]

  @windows [
    {"24h", "Last 24 hours"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"},
    {"all", "All time"}
  ]

  def kinds, do: @kinds

  @doc """
  The label for a kind, given either the atom or the string a URL carries.

  Filters arrive as query params, so this is reachable from a hand-typed URL;
  it resolves by string rather than converting, because `to_existing_atom` on
  an unrecognised param crashes the view.
  """
  def kind_label(kind) when is_atom(kind), do: Keyword.get(@kinds, kind, "Other")

  def kind_label(kind) when is_binary(kind) do
    Enum.find_value(@kinds, "Other", fn {k, label} -> to_string(k) == kind && label end)
  end

  def windows, do: @windows

  @doc """
  Merges activations and acts into one stream, newest first.

  Every event carries where it goes, because a row you cannot follow is a row
  that made you open another tab.
  """
  @spec build([map()], [map()], Scope.t()) :: [map()]
  def build(inbox, activity, scope) do
    (Enum.map(inbox, &from_activation(&1, scope)) ++ Enum.map(activity, &from_act(&1, scope)))
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp from_activation(entry, scope) do
    %{
      id: entry[:id],
      kind: :activation,
      at: entry[:inserted_at],
      actor: "cabinet",
      what: "classified #{entry[:class]}",
      target: entry[:summary] || entry[:event],
      detail: decision_detail(entry),
      result: entry[:status],
      tone: status_tone(entry[:status]),
      ministry: slug(entry[:ministry_slug]),
      to: ministry_path(scope, entry[:ministry_slug], :ruleset),
      needs: needs_of(entry)
    }
  end

  defp from_act(act, scope) do
    kind = kind_of(act[:action])

    %{
      id: act[:id],
      kind: kind,
      at: act[:at],
      actor: act[:actor],
      what: humanise(act[:action]),
      target: act[:target],
      detail: nil,
      result: act[:result],
      tone: result_tone(act[:result]),
      to: ministry_path(scope, act[:ministry] || slug(act[:target]), :ministry),
      # Acts recorded before the field existed carry the ministry in `target`
      # when the target happened to be a slug, and something else when it did
      # not; `slug/1` is what tells the two apart either way.
      ministry: act[:ministry] || slug(act[:target]),
      needs: nil
    }
  end

  # The Cabinet writes a small, closed set of actions — every `Activity.record`
  # call site in lib/ is covered here. Anything unmapped lands in :other rather
  # than being silently filed under something it is not.
  defp kind_of("wake"), do: :wake
  defp kind_of("stop"), do: :sleep
  defp kind_of("sleep"), do: :sleep
  defp kind_of("observed"), do: :observation
  defp kind_of("snapshot"), do: :observation
  defp kind_of("mode"), do: :policy
  defp kind_of("rule"), do: :policy
  defp kind_of("ruleset.publish"), do: :policy
  defp kind_of("ruleset.discard"), do: :policy
  defp kind_of("idle_stop_override"), do: :policy
  defp kind_of("set_config"), do: :policy
  defp kind_of("edit"), do: :registry
  defp kind_of("register"), do: :registry
  defp kind_of("start"), do: :activation
  defp kind_of("dismiss"), do: :activation
  defp kind_of("start_queued"), do: :activation
  defp kind_of("dismiss_queued"), do: :activation
  defp kind_of(_), do: :other

  defp humanise("observed"), do: "observed"
  defp humanise("start"), do: "started a queued activation"
  defp humanise("dismiss"), do: "dismissed a queued activation"
  defp humanise("idle_stop_override"), do: "held awake"
  defp humanise("mode"), do: "set the mode of"
  defp humanise("set_config"), do: "changed configuration"
  defp humanise("ruleset.publish"), do: "published a ruleset for"
  defp humanise("ruleset.discard"), do: "discarded a ruleset draft for"
  defp humanise("start_queued"), do: "started a queued activation"
  defp humanise("dismiss_queued"), do: "dismissed a queued activation"
  defp humanise("register"), do: "registered"
  defp humanise("edit"), do: "edited the registration of"
  defp humanise("snapshot"), do: "refreshed the snapshot of"
  defp humanise(action), do: to_string(action)

  defp decision_detail(entry) do
    case entry[:decision] do
      %{} = d ->
        rule = if d[:rule], do: " · rule #{d[:rule]}", else: ""
        "under #{d[:mode] || "?"} → #{d[:action] || entry[:status]}#{rule}"

      _ ->
        "recorded before decisions carried their provenance"
    end
  end

  @doc """
  What this event wants from a person, or nil.

  The Cabinet can only speak for what it holds: an activation it queued and is
  not going to start on its own, and one whose delivery it failed to hand over.
  Questions and approvals belong to a mission and live on the factory.
  """
  def needs_of(%{status: "queued"} = e),
    do: %{what: "A #{e[:class]} was queued rather than started", act: "Start", dismissable: true}

  def needs_of(%{status: "forward_failed"}),
    do: %{what: "A delivery was never handed to the factory", act: "Retry", dismissable: true}

  def needs_of(_), do: nil

  defp status_tone("queued"), do: :warn
  defp status_tone("waking"), do: :recon
  defp status_tone("forwarded"), do: :ok
  defp status_tone("forward_failed"), do: :crit
  defp status_tone(_), do: nil

  defp result_tone(nil), do: nil
  defp result_tone("running"), do: :ok
  defp result_tone("ok"), do: :ok

  defp result_tone(result) do
    r = to_string(result)

    cond do
      r =~ ~r/fail|error|refus/i -> :crit
      r =~ ~r/stopp|pending|starting/i -> :recon
      true -> nil
    end
  end

  # A slug or nothing. A ministry that differs from another only by a trailing
  # space reads as two ministries in the facet, and has.
  defp slug(nil), do: nil

  defp slug(value) do
    trimmed = value |> to_string() |> String.trim()
    if trimmed =~ ~r/^[a-z0-9][a-z0-9-]*$/, do: trimmed
  end

  defp ministry_path(_scope, nil, _level), do: nil

  defp ministry_path(scope, value, level) do
    case slug(value) do
      nil -> nil
      slug -> Scope.path(scope, level, ministry: slug)
    end
  end

  # ==========================================================================
  # Filtering
  # ==========================================================================

  @doc "An empty filter set — everything, last 30 days."
  def blank, do: %{kind: [], ministry: [], actor: [], result: [], when: "30d", q: ""}

  @doc "Reads filters out of query params, so a filtered view is a URL."
  @spec from_params(map()) :: map()
  def from_params(params) do
    %{
      kind: list_param(params["kind"]),
      ministry: list_param(params["ministry"]),
      actor: list_param(params["actor"]),
      result: list_param(params["result"]),
      when:
        if(params["when"] in Enum.map(@windows, &elem(&1, 0)), do: params["when"], else: "30d"),
      q: params["q"] || ""
    }
  end

  defp list_param(nil), do: []
  defp list_param(""), do: []
  defp list_param(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp list_param(value) when is_list(value), do: value

  @doc "The query string for a filter set. Blank filters contribute nothing."
  @spec to_query(map()) :: String.t()
  def to_query(filters) do
    blank = blank()

    [:kind, :ministry, :actor, :result]
    |> Enum.map(fn key -> {key, Enum.join(Map.get(filters, key, []), ",")} end)
    |> Kernel.++([{:when, filters.when}, {:q, filters.q}])
    |> Enum.reject(fn {key, value} -> value in ["", nil] or value == Map.get(blank, key) end)
    |> case do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  @doc "How many filters are narrowing the view — for the 'clear all' affordance."
  def active_count(filters) do
    blank = blank()

    Enum.count([:kind, :ministry, :actor, :result, :when, :q], fn key ->
      Map.get(filters, key) != Map.get(blank, key)
    end)
  end

  @spec filter([map()], map()) :: [map()]
  def filter(events, filters), do: Enum.filter(events, &passes?(&1, filters, nil))

  defp passes?(event, filters, skip) do
    in_window?(event, filters.when) and matches_query?(event, filters.q) and
      Enum.all?([:kind, :ministry, :actor, :result], fn key ->
        key == skip or selected(filters, key) == [] or
          to_string(value_of(event, key)) in selected(filters, key)
      end)
  end

  defp selected(filters, key), do: Map.get(filters, key, [])

  defp value_of(event, :kind), do: event.kind
  defp value_of(event, :ministry), do: event.ministry
  defp value_of(event, :actor), do: event.actor
  defp value_of(event, :result), do: event.tone || :neutral

  defp matches_query?(_event, ""), do: true

  defp matches_query?(event, q) do
    [event.what, event.target, event.detail, event.actor, event.result]
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
    |> String.contains?(String.downcase(q))
  end

  defp in_window?(_event, "all"), do: true

  defp in_window?(event, window) do
    hours = %{"24h" => 24, "7d" => 24 * 7, "30d" => 24 * 30}[window] || 24 * 30
    DateTime.diff(DateTime.utc_now(), event.at, :second) <= hours * 3600
  end

  @doc """
  One facet's options and their counts.

  Counted against everything *except* this facet's own selection, so the
  numbers say what you would get by also picking a value — which is the
  question, and not what a naive count answers.
  """
  @spec facet([map()], map(), atom()) :: [{term(), String.t(), non_neg_integer()}]
  def facet(events, filters, key) do
    base = Enum.filter(events, &passes?(&1, filters, key))
    counts = Enum.frequencies_by(base, &value_of(&1, key))

    events
    |> Enum.map(&value_of(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn value -> {value, facet_label(key, value), Map.get(counts, value, 0)} end)
    |> Enum.sort_by(fn {_value, label, count} -> {-count, label} end)
  end

  defp facet_label(:kind, kind), do: kind_label(kind)
  defp facet_label(:result, :ok), do: "succeeded"
  defp facet_label(:result, :warn), do: "warning"
  defp facet_label(:result, :crit), do: "failed"
  defp facet_label(:result, :recon), do: "in progress"
  defp facet_label(:result, _), do: "neutral"
  defp facet_label(_key, value), do: to_string(value)

  @doc "How many events fall inside each time window, whatever else is selected."
  def window_counts(events, filters) do
    Enum.map(@windows, fn {id, label} ->
      {id, label, Enum.count(events, &passes?(&1, %{filters | when: id}, nil))}
    end)
  end

  @doc "Toggles one value in one facet."
  def toggle(filters, key, value) do
    current = Map.get(filters, key, [])
    value = to_string(value)
    Map.put(filters, key, if(value in current, do: current -- [value], else: current ++ [value]))
  end
end
