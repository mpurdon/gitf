defmodule GiTF.Cabinet do
  @moduledoc """
  The Cabinet — the fleet's always-on front door (docs/plans/ministry.md).

  A Ministry is a client: a complete Section (factory) on its own EC2 box
  that sleeps to $0. The Cabinet is the one node that stays up. It holds
  the ministry registry, receives every ministry's GitHub webhooks,
  consults a per-ministry ruleset under an operator-set mode
  (normal / vacation / off), and decides to WAKE the Section and forward
  the event, QUEUE it for the operator, or DROP it. It never creates
  missions, never holds PATs or model credentials, and every Section's
  own events poller remains the backstop — a dead Cabinet loses
  timeliness, not events.

  Cabinet MODE is how the same release runs as a Cabinet: the supervision
  tree keeps the foundation (Archive, Config, PubSub) and the interface
  (dashboard, MCP) and skips the factory itself — no Major, no ghosts,
  no sector supervision, no background sweeps.
  """

  @doc "Whether this node runs as the Cabinet (`[cabinet] enabled` or app env)."
  @spec mode?() :: boolean()
  def mode? do
    Application.get_env(:gitf, :cabinet_mode, false) ||
      GiTF.Config.Provider.get([:cabinet, :enabled], false) == true
  rescue
    _ -> false
  end
end
