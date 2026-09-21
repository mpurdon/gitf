defmodule GiTF.Drain do
  @moduledoc """
  "Finish what you are doing, start nothing new" — the quiesce half of a
  graceful shutdown.

  A box that is about to be stopped has two things to get right, and only
  one of them was ever built. The finishing half exists: `GiTF.Exfil` runs
  an ordered teardown on SIGTERM (running ops demoted so they resume,
  ghosts checkpointed, Archive flushed), and the idle-stop timer already
  knows how to wait for quiet before powering off. The *starting* half did
  not: nothing stopped new work arriving while the box wound down, so a
  webhook, an Aramaki admission tick or an operator could begin a mission
  on a box that was thirty seconds from stopping, and a drain could race
  new arrivals forever.

  This is that missing gate, and it is deliberately one gate.
  `Major.Orchestrator.start_quest/2` is the single door every path goes
  through — webhook, Aramaki, CLI, HTTP API, dashboard, idle sweeper, MCP
  — so refusing there covers all of them at once and cannot be bypassed
  by a caller nobody remembered.

  ## What a drain does NOT do

  It does not stop work already running, answer held questions, or power
  anything off. The daemon runs as `gitf`, not root, and cannot halt the
  machine; stopping is the Cabinet's `ec2 stop-instances` or the root
  idle-stop timer. A drain only closes the door and lets the box go quiet,
  which is what makes "stop it when it is not busy" terminate instead of
  chasing a moving target.

  ## Why it is not durable

  The state lives in `:persistent_term` and dies with the BEAM, on
  purpose. A drain is a statement about *this* shutdown, and a box that
  wakes for a webhook must wake ready to work — a drain that survived a
  reboot would be a box that quietly refuses every mission until someone
  remembers why. The failure direction is "accepts work", which is the
  safe one for a flag whose whole job is to stop accepting it.

  For the same reason a drain expires on its own: an operator who drains a
  box and then gets distracted has a box that starts working again, not
  one that is mute until the next deploy.
  """

  require Logger

  @key {__MODULE__, :state}

  # Long enough to outlast any real drain — the longest thing a mission
  # waits on is a human, and held missions do not hold a drain open — and
  # short enough that a forgotten drain is a bad afternoon rather than a
  # silently dead box.
  @max_minutes 240

  @type t :: %{
          since: DateTime.t(),
          expires_at: DateTime.t(),
          reason: String.t() | nil,
          actor: String.t() | nil
        }

  @doc """
  Stops the box accepting new missions.

  Options: `:reason` and `:actor` (both recorded, both shown by
  `state/0` and on `/health`), and `:minutes` to bound how long the gate
  stays closed before it opens by itself (default #{@max_minutes}).

  Draining an already-draining box keeps the original `since` — the
  question "how long has this been winding down" must not be reset by a
  second tap — but takes the later expiry.
  """
  @spec begin(keyword()) :: {:ok, t()}
  def begin(opts \\ []) do
    minutes = opts |> Keyword.get(:minutes, @max_minutes) |> clamp()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, minutes * 60, :second)

    state = %{
      since: (state() && state().since) || now,
      expires_at: expires_at,
      reason: Keyword.get(opts, :reason),
      actor: Keyword.get(opts, :actor)
    }

    :persistent_term.put(@key, state)

    Logger.info(
      "Drain: no new missions for up to #{minutes}m" <>
        ((state.actor && " (by #{state.actor})") || "") <>
        ((state.reason && " — #{state.reason}") || "")
    )

    {:ok, state}
  end

  @doc "Reopens the door. Safe to call when nothing is draining."
  @spec cancel() :: :ok
  def cancel do
    if state(), do: Logger.info("Drain: cancelled, accepting missions again")
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The active drain, or `nil`.

  Expiry is evaluated on read rather than swept, so a drain that outlives
  its window is inert even though nothing has cleaned it up — the same
  shape as `GiTF.IdleStop.active/0`, and for the same reason.
  """
  @spec state() :: t() | nil
  def state do
    case :persistent_term.get(@key, nil) do
      %{expires_at: exp} = drain ->
        if DateTime.compare(DateTime.utc_now(), exp) == :lt, do: drain

      _ ->
        nil
    end
  end

  @doc "Whether the box is refusing new missions."
  @spec draining?() :: boolean()
  def draining?, do: state() != nil

  @doc """
  `:ok`, or `{:error, :draining}` when the box is winding down.

  The preflight `start_quest/2` runs, alongside the budget and provider
  ones. Kept here rather than inlined there so the refusal reads the same
  everywhere and there is one place to change the answer.
  """
  @spec preflight() :: :ok | {:error, :draining}
  def preflight do
    case state() do
      nil ->
        :ok

      drain ->
        Logger.info(
          "Drain: refused a mission start#{(drain.reason && " — #{drain.reason}") || ""}"
        )

        {:error, :draining}
    end
  end

  defp clamp(minutes) when is_integer(minutes) and minutes > 0,
    do: min(minutes, @max_minutes)

  defp clamp(_), do: @max_minutes
end
