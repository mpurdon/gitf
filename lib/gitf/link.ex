defmodule GiTF.Link do
  @moduledoc """
  Context module for the link_msg messaging system.

  Links are inter-agent messages that flow between the Major and her ghosts.
  Each link_msg is persisted to the store for auditability and also broadcast
  via PubSub for real-time subscribers.
  """

  alias GiTF.Archive

  @pubsub GiTF.PubSub

  # -- Public API ------------------------------------------------------------

  @doc """
  Sends a link_msg message, persisting it to the store and broadcasting
  via PubSub.

  Returns `{:ok, link_msg}` or `{:error, reason}`.
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

    {:ok, link_msg} = Archive.insert(:links, record)
    broadcast(to, {:link_received, link_msg})

    GiTF.Telemetry.emit([:gitf, :link_msg, :sent], %{}, %{
      from: from,
      to: to,
      subject: subject
    })

    {:ok, link_msg}
  end

  @doc """
  Lists link_msg messages with optional filters.

  ## Options

    * `:to` - filter by recipient
    * `:from` - filter by sender
    * `:read` - filter by read status (`true` or `false`)
    * `:limit` - maximum number of results (default: 50)
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    links = Archive.all(:links)

    links =
      case Keyword.get(opts, :to) do
        nil -> links
        v -> Enum.filter(links, &(&1.to == v))
      end

    links =
      case Keyword.get(opts, :from) do
        nil -> links
        v -> Enum.filter(links, &(&1.from == v))
      end

    links =
      case Keyword.get(opts, :read) do
        nil -> links
        v -> Enum.filter(links, &(&1.read == v))
      end

    links
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Lists link_msg messages associated with a specific op ID.
  """
  @spec list_by_op(String.t()) :: [map()]
  def list_by_op(op_id) do
    Archive.all(:links)
    |> Enum.filter(fn w ->
      meta = Map.get(w, :metadata)

      (is_map(meta) and Map.get(meta, :op_id) == op_id) or
        (is_binary(meta) and String.contains?(meta, op_id))
    end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Lists unread link_msg messages for a given recipient.
  """
  @spec list_unread(String.t()) :: [map()]
  def list_unread(recipient) do
    list(to: recipient, read: false)
  end

  @doc """
  Marks a link_msg message as read.

  Returns `{:ok, link_msg}` or `{:error, :not_found}`.
  """
  @spec mark_read(String.t()) :: {:ok, map()} | {:error, :not_found}
  def mark_read(link_id) do
    case Archive.get(:links, link_id) do
      nil ->
        {:error, :not_found}

      link_msg ->
        updated = %{link_msg | read: true}
        Archive.put(:links, updated)
    end
  end

  @doc """
  Sends a backup link_msg from a ghost, reporting progress.

  The body contains backup data: phase, files_changed, progress_pct.
  """
  @spec send_checkpoint(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_checkpoint(ghost_id, %{} = data) do
    body = Jason.encode!(data)
    __MODULE__.send(ghost_id, "major", "backup", body)
  end

  @doc """
  Sends a resource warning link_msg from a ghost.

  The body contains: type (e.g. :context_tokens, :time), current value, limit.
  """
  @spec send_resource_warning(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_resource_warning(ghost_id, %{} = data) do
    body = Jason.encode!(data)
    __MODULE__.send(ghost_id, "major", "resource_warning", body)
  end

  @doc """
  Sends a clarification request link_msg from a ghost to the queen.

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
  @spec topic(:major | :ghost | :sector, String.t() | nil) :: String.t()
  def topic(:major, _), do: "link:major"
  def topic(:ghost, id), do: "link_msg:ghost:#{id}"
  def topic(:sector, name), do: "link_msg:sector:#{name}"

  # -- Private helpers -------------------------------------------------------

  defp broadcast("major" = to, message) do
    Phoenix.PubSub.broadcast(@pubsub, "link:major", message)
  rescue
    e in ArgumentError ->
      _ = e
      :ok

    e ->
      require Logger
      Logger.error("Link broadcast failed for #{to}: #{Exception.message(e)}")
      :telemetry.execute([:gitf, :link_msg, :broadcast_error], %{}, %{to: to, error: e})
      :ok
  end

  defp broadcast(to, message) do
    Phoenix.PubSub.broadcast(@pubsub, "link_msg:#{to}", message)
  rescue
    e in ArgumentError ->
      # No subscribers — safe to ignore
      _ = e
      :ok

    e ->
      require Logger
      Logger.error("Link broadcast failed for #{to}: #{Exception.message(e)}")
      :telemetry.execute([:gitf, :link_msg, :broadcast_error], %{}, %{to: to, error: e})
      :ok
  end
end
