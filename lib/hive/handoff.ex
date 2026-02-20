defmodule Hive.Handoff do
  @moduledoc """
  Context-preserving bee restart mechanism.

  When a bee is replaced -- due to crash, context exhaustion, or manual
  restart -- the handoff system captures the outgoing bee's state and
  provides it to the incoming bee so work can continue seamlessly.

  The handoff is stored as a waggle message from the bee to itself with
  the subject "handoff". This keeps all state within the existing waggle
  infrastructure: no new tables, no new schemas, just a well-structured
  message that a new bee can consume when it starts.

  This is a pure context module. Every function transforms bee state into
  a structured handoff document and back.
  """

  alias Hive.Store

  @handoff_subject "handoff"

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates a handoff record for a bee.

  Captures the bee's current job state, recent waggles, cell info, and
  stores it as a waggle from the bee to itself with subject "handoff".
  
  Also creates a context snapshot for tracking purposes.

  Returns `{:ok, waggle}` with the handoff content.
  """
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(bee_id, opts \\ []) do
    with {:ok, context} <- build_handoff_context(bee_id, opts) do
      session_id = Keyword.get(opts, :session_id)

      context =
        if session_id do
          context <> "\n\n## Session ID\n#{session_id}"
        else
          context
        end

      # Create context snapshot for tracking
      Hive.Runtime.ContextMonitor.create_snapshot(bee_id)

      Hive.Waggle.send(bee_id, bee_id, @handoff_subject, context)
    end
  end

  @doc """
  Reads a handoff waggle and generates a briefing for the new bee.

  Takes a bee_id and a handoff waggle_id, marks the waggle as read,
  and returns the handoff context as markdown.
  """
  @spec resume(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resume(_bee_id, handoff_waggle_id) do
    case Store.get(:waggles, handoff_waggle_id) do
      nil ->
        {:error, :handoff_not_found}

      waggle ->
        Hive.Waggle.mark_read(waggle.id)
        briefing = format_resume_briefing(waggle)
        {:ok, briefing}
    end
  end

  @doc """
  Checks if there is an unread handoff waggle for this bee.

  Returns `{:ok, waggle}` if a handoff exists, `{:error, :no_handoff}` otherwise.
  """
  @spec detect_handoff(String.t()) :: {:ok, map()} | {:error, :no_handoff}
  def detect_handoff(bee_id) do
    waggle =
      Store.filter(:waggles, fn w ->
        w.to == bee_id and w.subject == @handoff_subject and w.read == false
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> List.first()

    case waggle do
      nil -> {:error, :no_handoff}
      w -> {:ok, w}
    end
  end

  @doc """
  Extracts a session ID from a handoff waggle body, if present.
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
  Builds the markdown state dump for a bee's handoff context.

  Gathers: current job status, cell info, recent waggles sent and received,
  and a summary of the bee's state.
  """
  @spec build_handoff_context(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_handoff_context(bee_id, _opts \\ []) do
    with {:ok, bee} <- fetch_bee(bee_id) do
      job = fetch_job(bee)
      cell = fetch_cell(bee_id)
      sent_waggles = Hive.Waggle.list(from: bee_id, limit: 10)
      received_waggles = Hive.Waggle.list(to: bee_id, limit: 10)

      markdown =
        [
          "# Handoff Context for #{bee.name} (#{bee.id})",
          "",
          "## Bee Status",
          "- Status: #{bee.status}",
          "- Created: #{bee.inserted_at}",
          "",
          "## Job",
          format_job_section(job),
          "",
          "## Workspace",
          format_cell_section(cell),
          "",
          "## Recent Messages Sent (#{length(sent_waggles)})",
          format_waggles_section(sent_waggles),
          "",
          "## Recent Messages Received (#{length(received_waggles)})",
          format_waggles_section(received_waggles),
          "",
          "## Instructions for Continuation",
          "- Review the job description above and continue where the previous bee left off.",
          "- Check the workspace path for any work in progress.",
          "- Send a waggle to the queen when you have completed the job or if you are blocked."
        ]
        |> Enum.join("\n")

      {:ok, markdown}
    end
  end

  # -- Private: data fetching ------------------------------------------------

  defp fetch_bee(bee_id) do
    case Store.get(:bees, bee_id) do
      nil -> {:error, :bee_not_found}
      bee -> {:ok, bee}
    end
  end

  defp fetch_job(%{job_id: nil}), do: nil

  defp fetch_job(%{job_id: job_id}) when is_binary(job_id) do
    Store.get(:jobs, job_id)
  end

  defp fetch_job(_bee), do: nil

  defp fetch_cell(bee_id) do
    Store.filter(:cells, fn c -> c.bee_id == bee_id end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> List.first()
  end

  # -- Private: formatting ---------------------------------------------------

  defp format_job_section(nil), do: "No job assigned."

  defp format_job_section(job) do
    lines = [
      "- Title: #{job.title}",
      "- ID: #{job.id}",
      "- Status: #{job.status}"
    ]

    lines =
      if job.description do
        lines ++ ["- Description:", "", job.description]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_cell_section(nil), do: "No workspace assigned."

  defp format_cell_section(cell) do
    [
      "- Path: `#{cell.worktree_path}`",
      "- Branch: `#{cell.branch}`",
      "- Status: #{cell.status}"
    ]
    |> Enum.join("\n")
  end

  defp format_waggles_section([]), do: "None."

  defp format_waggles_section(waggles) do
    waggles
    |> Enum.map(fn w ->
      read_marker = if w.read, do: "[read]", else: "[unread]"
      subject = w.subject || "(no subject)"
      "- #{read_marker} #{w.from} -> #{w.to}: #{subject}"
    end)
    |> Enum.join("\n")
  end

  defp format_resume_briefing(waggle) do
    [
      "# Handoff Briefing",
      "",
      "You are continuing work from a previous bee session.",
      "The handoff was created at #{waggle.inserted_at}.",
      "",
      "---",
      "",
      waggle.body || "No context was captured."
    ]
    |> Enum.join("\n")
  end
end
