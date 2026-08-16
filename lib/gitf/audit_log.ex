defmodule GiTF.AuditLog do
  @moduledoc """
  Append-only trail of privileged actions with actor attribution.

  Every entry answers "who did the dangerous thing, to what, when":
  approvals, rejections, settings writes. Records live in the
  `:audit_log` Archive collection and are never updated or deleted by
  application code — a trail the actor can rewrite is not a trail.

  This is the person-level half of the tailnet security model: Tailscale
  authenticates the device, `GiTF.Tailnet` resolves the person, and this
  module remembers what they did.
  """

  alias GiTF.Archive

  @collection :audit_log

  @doc """
  Records a privileged action. Fire-and-forget: audit failure is logged
  but never blocks the action itself (the action already happened).
  """
  @spec record(String.t(), String.t(), String.t(), map()) :: :ok
  def record(actor, action, subject, details \\ %{}) do
    entry = %{
      id: generate_id(),
      actor: actor,
      action: action,
      subject: subject,
      details: details,
      at: DateTime.utc_now()
    }

    case Archive.put(@collection, entry) do
      {:ok, _} -> :ok
      other -> log_failure(entry, other)
    end
  rescue
    e ->
      log_failure(%{action: action, subject: subject}, e)
  catch
    # A stopped Archive exits the caller (:noproc) rather than raising.
    :exit, reason ->
      log_failure(%{action: action, subject: subject}, {:exit, reason})
  end

  @doc "Most recent entries, newest first."
  @spec recent(non_neg_integer()) :: [map()]
  def recent(limit \\ 100) do
    @collection
    |> Archive.all()
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp generate_id do
    "aud-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp log_failure(entry, reason) do
    require Logger
    Logger.error("audit log write failed for #{inspect(entry)}: #{inspect(reason)}")
    :ok
  end
end
