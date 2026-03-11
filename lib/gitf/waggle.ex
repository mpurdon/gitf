defmodule GiTF.Waggle do
  @moduledoc """
  Context module for the waggle messaging system.

  Waggles are inter-agent messages that flow between the Major and her ghosts.
  Each waggle is persisted to the store for auditability and also broadcast
  via PubSub for real-time subscribers.
  """

  alias GiTF.Store

  @pubsub GiTF.PubSub

  # -- Public API ------------------------------------------------------------

  @doc """
  Sends a waggle message, persisting it to the store and broadcasting
  via PubSub.

  Returns `{:ok, waggle}` or `{:error, reason}`.
  """
  @spec send(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def send(from, to, subject, body, metadata \\ nil) do
    record = %{
      from: from,
      to: to,
      subject: subject,
      body: body,
      read: false,
      metadata: metadata
    }

    {:ok, waggle} = Store.insert(:waggles, record)
    broadcast(to, {:waggle_received, waggle})

    GiTF.Telemetry.emit([:gitf, :waggle, :sent], %{}, %{
      from: from,
      to: to,
      subject: subject
    })

    {:ok, waggle}
  end

  @doc """
  Lists waggle messages with optional filters.

  ## Options

    * `:to` - filter by recipient
    * `:from` - filter by sender
    * `:read` - filter by read status (`true` or `false`)
    * `:limit` - maximum number of results (default: 50)
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    waggles = Store.all(:waggles)

    waggles =
      case Keyword.get(opts, :to) do
        nil -> waggles
        v -> Enum.filter(waggles, &(&1.to == v))
      end

    waggles =
      case Keyword.get(opts, :from) do
        nil -> waggles
        v -> Enum.filter(waggles, &(&1.from == v))
      end

    waggles =
      case Keyword.get(opts, :read) do
        nil -> waggles
        v -> Enum.filter(waggles, &(&1.read == v))
      end

    waggles
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Lists unread waggle messages for a given recipient.
  """
  @spec list_unread(String.t()) :: [map()]
  def list_unread(recipient) do
    list(to: recipient, read: false)
  end

  @doc """
  Marks a waggle message as read.

  Returns `{:ok, waggle}` or `{:error, :not_found}`.
  """
  @spec mark_read(String.t()) :: {:ok, map()} | {:error, :not_found}
  def mark_read(waggle_id) do
    case Store.get(:waggles, waggle_id) do
      nil ->
        {:error, :not_found}

      waggle ->
        updated = %{waggle | read: true}
        Store.put(:waggles, updated)
    end
  end

  @doc """
  Sends a checkpoint waggle from a ghost, reporting progress.

  The body contains checkpoint data: phase, files_changed, progress_pct.
  """
  @spec send_checkpoint(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_checkpoint(ghost_id, %{} = data) do
    body = Jason.encode!(data)
    __MODULE__.send(ghost_id, "major", "checkpoint", body)
  end

  @doc """
  Sends a resource warning waggle from a ghost.

  The body contains: type (e.g. :context_tokens, :time), current value, limit.
  """
  @spec send_resource_warning(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_resource_warning(ghost_id, %{} = data) do
    body = Jason.encode!(data)
    __MODULE__.send(ghost_id, "major", "resource_warning", body)
  end

  @doc """
  Sends a clarification request waggle from a ghost to the queen.

  Used by ghosts operating under high cognitive friction that encounter
  ambiguous instructions.
  """
  @spec send_clarification(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_clarification(ghost_id, %{question: question} = data) do
    context = Map.get(data, :context, "")
    body = Jason.encode!(%{question: question, context: context})
    __MODULE__.send(ghost_id, "major", "clarification_needed", body)
  end

  @doc "Subscribes the calling process to a PubSub topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic_string) do
    Phoenix.PubSub.subscribe(@pubsub, topic_string)
  end

  @doc """
  Builds a canonical topic string for a given entity type and identifier.
  """
  @spec topic(:major | :ghost | :comb, String.t() | nil) :: String.t()
  def topic(:major, _), do: "link:major"
  def topic(:ghost, id), do: "waggle:ghost:#{id}"
  def topic(:comb, name), do: "waggle:comb:#{name}"

  # -- Private helpers -------------------------------------------------------

  defp broadcast(to, message) do
    Phoenix.PubSub.broadcast(@pubsub, "waggle:#{to}", message)
  rescue
    e in ArgumentError ->
      # No subscribers — safe to ignore
      _ = e
      :ok

    e ->
      require Logger
      Logger.error("Waggle broadcast failed for #{to}: #{Exception.message(e)}")
      :telemetry.execute([:gitf, :waggle, :broadcast_error], %{}, %{to: to, error: e})
      :ok
  end
end
