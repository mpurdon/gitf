defmodule GiTF.Costs do
  @moduledoc """
  Context module for token usage and cost tracking.

  Records per-ghost cost data extracted from Claude Code transcripts and
  provides aggregation queries for reporting.
  """

  alias GiTF.Store

  @default_model "google:gemini-2.5-flash"

  # -- Public API --------------------------------------------------------------

  @doc """
  Records a cost entry for a ghost.

  Automatically calculates `cost_usd` from token counts and model if not
  already provided. Sets `recorded_at` to now if not provided.

  Returns `{:ok, cost}` or `{:error, reason}`.
  """
  @spec record(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def record(ghost_id, attrs) do
    attrs =
      attrs
      |> Map.put(:ghost_id, ghost_id)
      |> maybe_set_recorded_at()
      |> maybe_calculate_cost()

    category = attrs[:category] || derive_category(attrs[:ghost_id])

    record = %{
      ghost_id: attrs[:ghost_id],
      input_tokens: attrs[:input_tokens] || 0,
      output_tokens: attrs[:output_tokens] || 0,
      cache_read_tokens: attrs[:cache_read_tokens] || 0,
      cache_write_tokens: attrs[:cache_write_tokens] || 0,
      cost_usd: attrs[:cost_usd],
      model: attrs[:model],
      category: category,
      recorded_at: attrs[:recorded_at]
    }

    {:ok, cost} = Store.insert(:costs, record)
    broadcast_cost_update(cost)

    GiTF.Telemetry.emit([:gitf, :token, :consumed], %{
      input: cost.input_tokens,
      output: cost.output_tokens,
      cost: cost.cost_usd
    }, %{
      model: cost.model,
      ghost_id: cost.ghost_id
    })

    {:ok, cost}
  end

  @doc "Returns all cost records for a given ghost."
  @spec for_bee(String.t()) :: [map()]
  def for_bee(ghost_id) do
    Store.filter(:costs, fn c -> c.ghost_id == ghost_id end)
    |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})
  end

  @doc """
  Returns all cost records for ghosts participating in a quest.
  """
  @spec for_quest(String.t()) :: [map()]
  def for_quest(quest_id) do
    ghost_ids =
      GiTF.Jobs.list(quest_id: quest_id)
      |> Enum.map(& &1.ghost_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ghost_ids do
      [] ->
        []

      ids ->
        Store.filter(:costs, fn c -> c.ghost_id in ids end)
        |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})
    end
  end

  @doc "Sums the `cost_usd` field across a list of cost records."
  @spec total([map()]) :: float()
  def total(costs) do
    costs
    |> Enum.reduce(0.0, fn c, acc -> acc + c.cost_usd end)
    |> Float.round(6)
  end

  @doc """
  Returns an aggregate summary of all recorded costs.
  """
  @spec summary() :: map()
  def summary do
    costs = Store.all(:costs)

    %{
      total_cost: total(costs),
      total_input_tokens: costs |> Enum.map(&Map.get(&1, :input_tokens, 0)) |> Enum.sum(),
      total_output_tokens: costs |> Enum.map(&Map.get(&1, :output_tokens, 0)) |> Enum.sum(),
      by_model: group_costs_by(costs, &Map.get(&1, :model)),
      by_bee: group_costs_by(costs, &Map.get(&1, :ghost_id)),
      by_category: group_costs_by(costs, &Map.get(&1, :category, "unknown"))
    }
  end

  @doc """
  Calculates the USD cost from token counts and model.
  Pure function -- no store access.
  """
  @spec calculate_cost(map()) :: float()
  def calculate_cost(attrs) do
    pricing = GiTF.Runtime.Models.pricing()
    pricing = if map_size(pricing) > 0, do: pricing, else: default_pricing()

    model = Map.get(attrs, :model) || Map.get(attrs, "model") || @default_model
    default_prices = %{input: 0.15, output: 0.60, cache_read: 0.0375, cache_write: 0.0}
    prices = Map.get(pricing, model, pricing[@default_model] || default_prices)

    input = token_count(attrs, :input_tokens) * prices.input
    output = token_count(attrs, :output_tokens) * prices.output
    cache_read = token_count(attrs, :cache_read_tokens) * prices.cache_read
    cache_write = token_count(attrs, :cache_write_tokens) * prices.cache_write

    ((input + output + cache_read + cache_write) / 1_000_000)
    |> Float.round(6)
  end

  # -- Private helpers ---------------------------------------------------------

  @planning_phases ~w(research requirements design planning)
  @verification_phases ~w(review validation)

  defp derive_category("major"), do: "orchestration"

  defp derive_category(ghost_id) when is_binary(ghost_id) do
    with {:ok, ghost} <- GiTF.Ghosts.get(ghost_id),
         job_id when is_binary(job_id) <- Map.get(ghost, :job_id),
         {:ok, job} <- GiTF.Jobs.get(job_id) do
      cond do
        Map.get(job, :phase_job, false) and job[:phase] in @planning_phases ->
          "planning"

        Map.get(job, :phase_job, false) and job[:phase] in @verification_phases ->
          "verification"

        true ->
          "implementation"
      end
    else
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp derive_category(_), do: "unknown"

  # Fallback pricing table — ensures existing tests pass without Plugin.Manager running
  defp default_pricing do
    %{
      # Gemini models (primary defaults)
      "google:gemini-2.5-pro" => %{
        input: 1.25,
        output: 10.0,
        cache_read: 0.315,
        cache_write: 0.0
      },
      "google:gemini-2.5-flash" => %{
        input: 0.15,
        output: 0.60,
        cache_read: 0.0375,
        cache_write: 0.0
      },
      "google:gemini-2.0-flash" => %{
        input: 0.10,
        output: 0.40,
        cache_read: 0.025,
        cache_write: 0.0
      },
      # Anthropic models (available via reqllm or bedrock)
      "anthropic:claude-opus-4-6" => %{
        input: 15.0,
        output: 75.0,
        cache_read: 1.50,
        cache_write: 18.75
      },
      "anthropic:claude-sonnet-4-6" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "anthropic:claude-haiku-4-5" => %{
        input: 0.80,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      # Legacy CLI model names (backwards compat)
      "claude-sonnet-4-20250514" => %{
        input: 3.0,
        output: 15.0,
        cache_read: 0.30,
        cache_write: 3.75
      },
      "claude-opus-4-20250514" => %{
        input: 15.0,
        output: 75.0,
        cache_read: 1.50,
        cache_write: 18.75
      }
    }
  end

  defp broadcast_cost_update(cost) do
    Phoenix.PubSub.broadcast(GiTF.PubSub, "section:costs", {:cost_recorded, cost})
  rescue
    _ -> :ok
  end

  defp maybe_set_recorded_at(%{recorded_at: _} = attrs), do: attrs

  defp maybe_set_recorded_at(attrs) do
    Map.put(attrs, :recorded_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp maybe_calculate_cost(%{cost_usd: _} = attrs), do: attrs

  defp maybe_calculate_cost(attrs) do
    Map.put(attrs, :cost_usd, calculate_cost(attrs))
  end

  defp token_count(attrs, key) do
    string_key = Atom.to_string(key)
    (Map.get(attrs, key) || Map.get(attrs, string_key) || 0) * 1.0
  end

  defp group_costs_by(costs, key_fn) do
    costs
    |> Enum.group_by(key_fn)
    |> Map.new(fn {key, group} ->
      {key || "unknown",
       %{
         cost: total(group),
         input_tokens: Enum.reduce(group, 0, fn c, acc -> acc + c.input_tokens end),
         output_tokens: Enum.reduce(group, 0, fn c, acc -> acc + c.output_tokens end)
       }}
    end)
  end
end
