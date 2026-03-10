defmodule Hive.CircuitBreaker do
  @moduledoc """
  ETS-backed circuit breaker with exponential backoff for external services.

  Prevents wasted spawn-fail-retry cycles when an API is down by tracking
  failures per service key and transitioning through three states:

      closed  ->  open  ->  half_open  ->  closed
                   ^                        |
                   |________________________|  (on failure in half_open)

  Also provides `call_with_retry/3` for automatic retry with exponential
  backoff for retryable errors (429, 503, 529).
  """

  require Logger

  @table :hive_circuit_breaker
  @failure_threshold 5
  @reset_timeout_ms :timer.seconds(30)
  @max_retries 4
  @base_delay_ms 1_000

  @retryable_status_codes [429, 503, 529]

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

  @doc """
  Execute `fun` with automatic retry and exponential backoff.

  Retries on retryable errors (429, 503, etc.) up to `max_retries` times
  with exponential backoff. Falls back to `fallback_fn` if provided and
  all retries are exhausted.

  ## Options

    * `:max_retries` - max retry attempts (default: 4)
    * `:fallback` - `(-> {:ok, term()} | {:error, term()})` called on exhaustion
  """
  @spec call_with_retry(String.t(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call_with_retry(service_key, fun, opts \\ []) do
    max = Keyword.get(opts, :max_retries, @max_retries)
    fallback = Keyword.get(opts, :fallback)

    do_retry(service_key, fun, 0, max, fallback)
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

  # -- Private: retry with backoff --------------------------------------------

  defp do_retry(_service_key, _fun, attempt, max, fallback) when attempt > max do
    if fallback do
      Logger.info("All retries exhausted, trying fallback")
      fallback.()
    else
      {:error, :retries_exhausted}
    end
  end

  defp do_retry(service_key, fun, attempt, max, fallback) do
    case call(service_key, fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, :circuit_open} ->
        # Wait for circuit reset
        delay = backoff_delay(attempt)
        Logger.info("Circuit open for #{service_key}, waiting #{delay}ms (attempt #{attempt + 1}/#{max + 1})")
        Process.sleep(delay)
        do_retry(service_key, fun, attempt + 1, max, fallback)

      {:error, reason} ->
        if retryable_error?(reason) and attempt < max do
          delay = backoff_delay(attempt)
          Logger.info("Retryable error for #{service_key}: #{inspect(reason)}, retrying in #{delay}ms (#{attempt + 1}/#{max + 1})")
          Process.sleep(delay)
          do_retry(service_key, fun, attempt + 1, max, fallback)
        else
          if fallback and attempt >= max do
            Logger.info("Non-retryable error after #{attempt} attempts, trying fallback")
            fallback.()
          else
            {:error, reason}
          end
        end
    end
  end

  defp retryable_error?({:http_error, status, _}) when status in @retryable_status_codes, do: true
  defp retryable_error?({:http_error, status}) when status in @retryable_status_codes, do: true
  defp retryable_error?(:rate_limited), do: true
  defp retryable_error?(:overloaded), do: true
  defp retryable_error?(:timeout), do: true
  defp retryable_error?(:econnrefused), do: true
  defp retryable_error?(:closed), do: true
  defp retryable_error?(msg) when is_binary(msg) do
    lower = String.downcase(msg)
    String.contains?(lower, "rate") or
      String.contains?(lower, "429") or
      String.contains?(lower, "503") or
      String.contains?(lower, "overloaded") or
      String.contains?(lower, "timeout") or
      String.contains?(lower, "connection")
  end
  defp retryable_error?(_), do: false

  defp backoff_delay(attempt) do
    # Exponential backoff with jitter: base * 2^attempt + random(0..base)
    base = @base_delay_ms * :math.pow(2, attempt) |> trunc()
    jitter = :rand.uniform(max(@base_delay_ms, 1))
    min(base + jitter, 60_000)
  end

  # -- Private: circuit breaker core ------------------------------------------

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
