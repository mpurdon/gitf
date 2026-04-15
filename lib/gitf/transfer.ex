defmodule GiTF.Transfer do
  @moduledoc """
  Context-preserving ghost restart mechanism.

  When a ghost is replaced -- due to crash, context exhaustion, or manual
  restart -- the transfer system captures the outgoing ghost's state and
  provides it to the incoming ghost so work can continue seamlessly.

  The transfer is stored as a link_msg message from the ghost to itself with
  the subject "transfer". This keeps all state within the existing link_msg
  infrastructure: no new tables, no new schemas, just a well-structured
  message that a new ghost can consume when it starts.

  This is a pure context module. Every function transforms ghost state into
  a structured transfer document and back.
  """

  alias GiTF.Archive

  @transfer_subject "transfer"

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates a transfer record for a ghost.

  Captures the ghost's current op state, recent links, shell info, and
  stores it as a link_msg from the ghost to itself with subject "transfer".

  Also creates a context snapshot for tracking purposes.

  Returns `{:ok, link_msg}` with the transfer content.
  """
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(ghost_id, opts \\ []) do
    with {:ok, context} <- build_handoff_context(ghost_id, opts) do
      session_id = Keyword.get(opts, :session_id)

      context =
        if session_id do
          context <> "\n\n## Session ID\n#{session_id}"
        else
          context
        end

      # Create context snapshot for tracking
      GiTF.Runtime.ContextMonitor.create_snapshot(ghost_id)

      GiTF.Link.send(ghost_id, ghost_id, @transfer_subject, context)
    end
  end

  @doc """
  Reads a transfer link_msg and generates a briefing for the new ghost.

  Takes a ghost_id and a transfer link_id, marks the link_msg as read,
  and returns the transfer context as markdown.
  """
  @spec resume(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resume(_ghost_id, transfer_link_id) do
    case Archive.get(:links, transfer_link_id) do
      nil ->
        {:error, :transfer_not_found}

      link_msg ->
        GiTF.Link.mark_read(link_msg.id)
        briefing = format_resume_briefing(link_msg)
        {:ok, briefing}
    end
  end

  @doc """
  Checks if there is an unread transfer link_msg for this ghost.

  Returns `{:ok, link_msg}` if a transfer exists, `{:error, :no_handoff}` otherwise.
  """
  @spec detect_handoff(String.t()) :: {:ok, map()} | {:error, :no_handoff}
  def detect_handoff(ghost_id) do
    link_msg =
      Archive.filter(:links, fn w ->
        w.to == ghost_id and w.subject == @transfer_subject and w.read == false
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> List.first()

    case link_msg do
      nil -> {:error, :no_handoff}
      w -> {:ok, w}
    end
  end

  @doc """
  Extracts a session ID from a transfer link_msg body, if present.
  """
  @spec extract_session_id(String.t() | nil) :: String.t() | nil
  def extract_session_id(nil), do: nil

  def extract_session_id(body) do
    case Regex.run(~r/## Session ID\n(.+)/, body) do
      [_, session_id] -> String.trim(session_id)
      _ -> nil
    end
  end

  @doc """
  Builds the markdown state dump for a ghost's transfer context.

  Gathers: current op status, shell info, recent links sent and received,
  and a summary of the ghost's state.
  """
  @spec build_handoff_context(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_handoff_context(ghost_id, _opts \\ []) do
    with {:ok, ghost} <- fetch_bee(ghost_id) do
      op = fetch_job(ghost)
      shell = fetch_cell(ghost_id)
      sent_waggles = GiTF.Link.list(from: ghost_id, limit: 10)
      received_waggles = GiTF.Link.list(to: ghost_id, limit: 10)
      backup_section = build_checkpoint_section(ghost_id)

      error_section = build_error_section(ghost_id)

      markdown =
        [
          "# Transfer Context for #{Map.get(ghost, :name, ghost.id)} (#{ghost.id})",
          "",
          "## Ghost Status",
          "- Status: #{ghost.status}",
          "- Created: #{ghost.inserted_at}",
          "",
          "## Job",
          format_job_section(op),
          "",
          "## Workspace",
          format_cell_section(shell),
          "",
          backup_section,
          error_section,
          "## Recent Messages Sent (#{length(sent_waggles)})",
          format_waggles_section(sent_waggles),
          "",
          "## Recent Messages Received (#{length(received_waggles)})",
          format_waggles_section(received_waggles),
          "",
          "## Instructions for Continuation",
          "- Review the op description above and continue where the previous ghost left off.",
          "- Check the workspace path for any work in progress.",
          "- Avoid the error patterns listed above if present.",
          "- Send a link_msg to the queen when you have completed the op or if you are blocked."
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      {:ok, markdown}
    end
  end

  # -- Private: data fetching ------------------------------------------------

  defp fetch_bee(ghost_id) do
    case Archive.get(:ghosts, ghost_id) do
      nil -> {:error, :ghost_not_found}
      ghost -> {:ok, ghost}
    end
  end

  defp fetch_job(%{op_id: nil}), do: nil

  defp fetch_job(%{op_id: op_id}) when is_binary(op_id) do
    Archive.get(:ops, op_id)
  end

  defp fetch_job(_ghost), do: nil

  defp fetch_cell(ghost_id) do
    Archive.filter(:shells, fn c -> c.ghost_id == ghost_id end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  # -- Private: formatting ---------------------------------------------------

  defp format_job_section(nil), do: "No op assigned."

  defp format_job_section(op) do
    lines = [
      "- Title: #{op.title}",
      "- ID: #{op.id}",
      "- Status: #{op.status}"
    ]

    lines =
      if op.description do
        lines ++ ["- Description:", "", op.description]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_cell_section(nil), do: "No workspace assigned."

  defp format_cell_section(shell) do
    [
      "- Path: `#{shell.worktree_path}`",
      "- Branch: `#{shell.branch}`",
      "- Status: #{shell.status}"
    ]
    |> Enum.join("\n")
  end

  defp format_waggles_section([]), do: "None."

  defp format_waggles_section(links) do
    links
    |> Enum.map(fn w ->
      read_marker = if w.read, do: "[read]", else: "[unread]"
      subject = w.subject || "(no subject)"
      "- #{read_marker} #{w.from} -> #{w.to}: #{subject}"
    end)
    |> Enum.join("\n")
  end

  defp build_error_section(ghost_id) do
    # Gather recent error links for this ghost
    error_waggles =
      Archive.filter(:links, fn w ->
        w.from == ghost_id and
          w.subject in [
            "job_failed",
            "verification_failed",
            "validation_failed",
            "merge_conflict"
          ]
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(5)

    if error_waggles == [] do
      ""
    else
      lines =
        Enum.map(error_waggles, fn w ->
          "- [#{w.subject}] #{String.slice(w.body || "", 0, 200)}"
        end)

      "## Previous Errors (avoid these patterns)\n\n" <> Enum.join(lines, "\n") <> "\n\n"
    end
  rescue
    _ -> ""
  end

  defp build_checkpoint_section(ghost_id) do
    case GiTF.Backup.load(ghost_id) do
      {:ok, backup} ->
        GiTF.Backup.build_resume_prompt(backup) <> "\n\n"

      {:error, :not_found} ->
        ""
    end
  end

  defp format_resume_briefing(link_msg) do
    [
      "# Transfer Briefing",
      "",
      "You are continuing work from a previous ghost session.",
      "The transfer was created at #{link_msg.inserted_at}.",
      "",
      "---",
      "",
      link_msg.body || "No context was captured."
    ]
    |> Enum.join("\n")
  end
end
