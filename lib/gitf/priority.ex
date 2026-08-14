defmodule GiTF.Priority do
  @moduledoc """
  Priority inference, comparison, and decay logic for mission scheduling.

  Pure functions — no process state. Missions carry a `:priority` atom
  (`:critical`, `:high`, `:normal`, `:low`, `:background`) that determines
  scheduling order. Priority can be manually set, inferred from the mission
  goal text, or left at the `:normal` default.

  ## Starvation Prevention

  Missions that have been waiting too long get automatic priority bumps
  via `effective_priority/1`. The decay thresholds are configurable under
  `[major] priority_decay_minutes` in config. After enough wait time,
  even `:background` missions eventually reach `:critical`.

  ## Hold-Back Rule

  The scheduler uses `hold_back?/1` to check whether a priority level
  should be suppressed when high-priority work is pending.
  """

  @levels [:critical, :high, :normal, :low, :background]
  @weights %{critical: 0, high: 1, normal: 2, low: 3, background: 4}
  @weights_to_priorities Map.new(@weights, fn {k, v} -> {v, k} end)

  @critical_patterns [
    ~r/\bproduction\b/i,
    ~r/\boutage\b/i,
    ~r/\bsecurity vulnerability\b/i,
    ~r/\bCVE\b/,
    ~r/\bexploit\b/i
  ]

  @high_patterns [
    ~r/\bfix\b/i,
    ~r/\bbug\b/i,
    ~r/\burgent\b/i,
    ~r/\bbroken\b/i,
    ~r/\bcrash\b/i,
    ~r/\bregression\b/i,
    ~r/\bblocking\b/i,
    ~r/\bhotfix\b/i,
    ~r/\bincident\b/i
  ]

  @low_patterns [
    ~r/\brefactor\b/i,
    ~r/\bcleanup\b/i,
    ~r/\bcosmetic\b/i,
    ~r/\brename\b/i,
    ~r/\bformatting\b/i,
    ~r/\bstyle\b/i
  ]

  @background_patterns [
    ~r/\bchore\b/i,
    ~r/\bhousekeeping\b/i,
    ~r/\btidy\b/i,
    ~r/\bpolish\b/i,
    ~r/\bnice.to.have\b/i
  ]

  @default_decay_minutes [30, 60, 120, 240]

  # -- Public API --------------------------------------------------------------

  @doc "Returns all valid priority levels in order from highest to lowest."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc "Returns the integer weight for a priority atom. Lower = higher priority."
  @spec weight(atom()) :: non_neg_integer()
  def weight(priority) when is_map_key(@weights, priority), do: @weights[priority]
  def weight(_), do: @weights[:normal]

  @doc """
  Compares two priority atoms. Returns `:lt`, `:eq`, or `:gt`.
  `:lt` means `a` is higher priority than `b`.
  """
  @spec compare(atom(), atom()) :: :lt | :eq | :gt
  def compare(a, b) do
    wa = weight(a)
    wb = weight(b)

    cond do
      wa < wb -> :lt
      wa > wb -> :gt
      true -> :eq
    end
  end

  @doc "Returns true if the given atom is a valid priority level."
  @spec valid?(term()) :: boolean()
  def valid?(priority), do: priority in @levels

  @doc "Returns true if the priority is `:critical` or `:high`."
  @spec high_priority?(atom()) :: boolean()
  def high_priority?(priority), do: priority in [:critical, :high]

  @doc "Returns true if the priority should be held back (`:low` or `:background`)."
  @spec hold_back?(atom()) :: boolean()
  def hold_back?(priority), do: priority in [:low, :background]

  @doc "Parses a string into a priority atom."
  @spec parse(String.t()) :: {:ok, atom()} | {:error, :invalid_priority}
  def parse(string) when is_binary(string) do
    atom =
      string
      |> String.downcase()
      |> String.trim()
      |> String.to_existing_atom()

    if valid?(atom), do: {:ok, atom}, else: {:error, :invalid_priority}
  rescue
    ArgumentError -> {:error, :invalid_priority}
  end

  @doc """
  Infers priority from a mission goal string.

  Returns `{priority, :inferred}`. Scans for keyword patterns in priority
  order — first match wins. Returns `{:normal, :inferred}` if no match.
  """
  @spec infer_from_goal(String.t()) :: {atom(), :inferred}
  def infer_from_goal(goal) when is_binary(goal) do
    priority =
      cond do
        matches_any?(goal, @critical_patterns) -> :critical
        matches_any?(goal, @high_patterns) -> :high
        matches_any?(goal, @low_patterns) -> :low
        matches_any?(goal, @background_patterns) -> :background
        true -> :normal
      end

    {priority, :inferred}
  end

  def infer_from_goal(_), do: {:normal, :inferred}

  @doc """
  Computes the effective priority for a mission after applying decay.

  Missions that have been waiting longer than the decay thresholds get
  their priority bumped up one level per threshold crossed.
  """
  @spec effective_priority(map()) :: atom()
  def effective_priority(mission) do
    base_priority = Map.get(mission, :priority, :normal)
    base_weight = weight(base_priority)

    if base_weight == 0 do
      weight_to_priority(0)
    else
      wait_minutes = wait_time_minutes(mission)
      decay_thresholds = get_decay_thresholds()
      bumps = count_decay_bumps(wait_minutes, decay_thresholds)
      effective_weight = max(base_weight - bumps, 0)
      weight_to_priority(effective_weight)
    end
  end

  # -- Private -----------------------------------------------------------------

  defp matches_any?(text, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, text))
  end

  defp wait_time_minutes(mission) do
    reference =
      Map.get(mission, :priority_set_at) ||
        Map.get(mission, :inserted_at) ||
        DateTime.utc_now()

    DateTime.diff(DateTime.utc_now(), coerce_datetime(reference), :second) / 60
  end

  # Missions fetched over the REST API (remote CLI mode) carry timestamps as
  # strings; local-mode missions carry DateTime structs. Accept both.
  defp coerce_datetime(%DateTime{} = dt), do: dt

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.replace(value, " ", "T")) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp coerce_datetime(_), do: DateTime.utc_now()

  defp count_decay_bumps(wait_minutes, thresholds) do
    Enum.count(thresholds, &(wait_minutes >= &1))
  end

  defp get_decay_thresholds do
    case GiTF.Config.Provider.get([:major, :priority_decay_minutes]) do
      mins when is_list(mins) and length(mins) == length(@levels) - 1 -> mins
      _ -> @default_decay_minutes
    end
  end

  defp weight_to_priority(w), do: Map.get(@weights_to_priorities, w, :background)
end
