defmodule GiTF.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for channels and model APIs.

  Each bucket has a max capacity and refill rate. Requests that exceed
  the rate are queued and drained at the allowed rate.
  """

  use GenServer

  require Logger

  # -- Public API ------------------------------------------------------------

  @doc "Starts a rate limiter with the given bucket config."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Requests permission to perform an action. Returns `:ok` immediately if
  tokens are available, or `{:ok, delay_ms}` if the caller should wait.
  """
  @spec acquire(GenServer.server(), pos_integer()) :: :ok | {:ok, non_neg_integer()}
  def acquire(server, count \\ 1) do
    GenServer.call(server, {:acquire, count})
  end

  @doc "Returns current bucket state for inspection."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    max_tokens = Keyword.get(opts, :max_tokens, 30)
    refill_rate = Keyword.get(opts, :refill_rate, 30)
    refill_interval = Keyword.get(opts, :refill_interval, 1_000)

    state = %{
      tokens: max_tokens,
      max_tokens: max_tokens,
      refill_rate: refill_rate,
      refill_interval: refill_interval,
      queue: :queue.new(),
      last_refill: System.monotonic_time(:millisecond)
    }

    schedule_refill(refill_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, count}, _from, state) do
    state = refill_tokens(state)

    if state.tokens >= count do
      {:reply, :ok, %{state | tokens: state.tokens - count}}
    else
      deficit = count - state.tokens
      delay_ms = ceil(deficit / state.refill_rate * state.refill_interval)
      {:reply, {:ok, delay_ms}, %{state | tokens: 0}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:tokens, :max_tokens, :refill_rate]), state}
  end

  @impl true
  def handle_info(:refill, state) do
    state = refill_tokens(state)
    schedule_refill(state.refill_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("RateLimiter ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private ---------------------------------------------------------------

  defp refill_tokens(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_refill
    new_tokens = elapsed / state.refill_interval * state.refill_rate
    tokens = min(state.max_tokens, state.tokens + new_tokens)
    %{state | tokens: tokens, last_refill: now}
  end

  defp schedule_refill(interval) do
    Process.send_after(self(), :refill, interval)
  end
end
