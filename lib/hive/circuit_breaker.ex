defmodule Hive.CircuitBreaker do
  @moduledoc """
  ETS-backed circuit breaker for external services.

  Prevents wasted spawn-fail-retry cycles when an API is down by tracking
  failures per service key and transitioning through three states:

      closed  ->  open  ->  half_open  ->  closed
                   ^                        |
                   |________________________|  (on failure in half_open)

  ## Usage

      case Hive.CircuitBreaker.call("claude-api", fn -> spawn_model(...) end) do
        {:ok, result} -> result
        {:error, :circuit_open} -> use_fallback()
        {:error, reason} -> handle_error(reason)
      end
  """

  require Logger

  @table :hive_circuit_breaker
  @failure_threshold 5
  @reset_timeout_ms :timer.seconds(30)

  @type state :: :closed | :open | :half_open

  @doc "Initialize the ETS table. Call once at application startup."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Execute `fun` through the circuit breaker for `service_key`.

  Returns `{:ok, result}` on success, `{:error, :circuit_open}` if the
  circuit is open, or `{:error, reason}` on failure.
  """
  @spec call(String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def call(service_key, fun) do
    case get_state(service_key) do
      :open ->
        if reset_timeout_elapsed?(service_key) do
          set_state(service_key, :half_open)
          try_call(service_key, fun)
        else
          {:error, :circuit_open}
        end

      :half_open ->
        try_call(service_key, fun)

      :closed ->
        try_call(service_key, fun)
    end
  end

  @doc "Returns the current circuit state for a service."
  @spec get_state(String.t()) :: state()
  def get_state(service_key) do
    case :ets.lookup(@table, {:state, service_key}) do
      [{_, state}] -> state
      [] -> :closed
    end
  rescue
    ArgumentError -> :closed
  end

  @doc "Manually reset a circuit to closed."
  @spec reset(String.t()) :: :ok
  def reset(service_key) do
    set_state(service_key, :closed)
    set_failure_count(service_key, 0)
    :ok
  end

  @doc "Returns the current failure count for a service."
  @spec failure_count(String.t()) :: non_neg_integer()
  def failure_count(service_key) do
    case :ets.lookup(@table, {:failures, service_key}) do
      [{_, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # -- Private ---------------------------------------------------------------

  defp try_call(service_key, fun) do
    case fun.() do
      {:ok, result} ->
        record_success(service_key)
        {:ok, result}

      {:error, reason} ->
        record_failure(service_key)
        {:error, reason}
    end
  rescue
    e ->
      record_failure(service_key)
      {:error, Exception.message(e)}
  end

  defp record_success(service_key) do
    set_state(service_key, :closed)
    set_failure_count(service_key, 0)
  end

  defp record_failure(service_key) do
    count = failure_count(service_key) + 1
    set_failure_count(service_key, count)

    if count >= @failure_threshold do
      Logger.warning("Circuit breaker OPEN for #{service_key} after #{count} failures")
      set_state(service_key, :open)
      set_opened_at(service_key)
    end
  end

  defp set_state(service_key, state) do
    :ets.insert(@table, {{:state, service_key}, state})
  rescue
    ArgumentError -> :ok
  end

  defp set_failure_count(service_key, count) do
    :ets.insert(@table, {{:failures, service_key}, count})
  rescue
    ArgumentError -> :ok
  end

  defp set_opened_at(service_key) do
    :ets.insert(@table, {{:opened_at, service_key}, System.monotonic_time(:millisecond)})
  rescue
    ArgumentError -> :ok
  end

  defp reset_timeout_elapsed?(service_key) do
    case :ets.lookup(@table, {:opened_at, service_key}) do
      [{_, opened_at}] ->
        System.monotonic_time(:millisecond) - opened_at >= @reset_timeout_ms

      [] ->
        true
    end
  rescue
    ArgumentError -> true
  end
end
