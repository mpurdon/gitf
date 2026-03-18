defmodule GiTF.TransferTest do
  use GiTF.StoreCase

  alias GiTF.Transfer
  alias GiTF.Archive

  setup do
    # Set up a full ghost with op, shell, and links
    {:ok, sector} =
      Archive.insert(:sectors, %{name: "transfer-sector-#{:erlang.unique_integer([:positive])}"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "transfer-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, op} =
      GiTF.Ops.create(%{
        title: "Implement feature X",
        description: "Build the X feature with proper tests",
        mission_id: mission.id,
        sector_id: sector.id
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{name: "transfer-ghost", status: "working", op_id: op.id})

    {:ok, shell} =
      Archive.insert(:shells, %{
        ghost_id: ghost.id,
        sector_id: sector.id,
        worktree_path: "/tmp/transfer-worktree",
        branch: "ghost/#{ghost.id}",
        status: "active"
      })

    # Create some links to/from this ghost
    {:ok, _sent} =
      GiTF.Link.send(ghost.id, "major", "progress", "50% done with feature X")

    {:ok, _received} =
      GiTF.Link.send("major", ghost.id, "guidance", "Focus on the API first")

    %{ghost: ghost, op: op, shell: shell, sector: sector, mission: mission}
  end

  describe "create/2" do
    test "creates a transfer link_msg for a ghost", ctx do
      assert {:ok, link_msg} = Transfer.create(ctx.ghost.id)

      assert link_msg.from == ctx.ghost.id
      assert link_msg.to == ctx.ghost.id
      assert link_msg.subject == "transfer"
      assert link_msg.read == false

      # The body should contain transfer context
      assert link_msg.body =~ "Transfer Context"
      assert link_msg.body =~ ctx.ghost.name
      assert link_msg.body =~ ctx.op.title
      assert link_msg.body =~ ctx.shell.worktree_path
      assert link_msg.body =~ ctx.shell.branch
    end

    test "captures op description in transfer", ctx do
      assert {:ok, link_msg} = Transfer.create(ctx.ghost.id)

      assert link_msg.body =~ "Implement feature X"
      assert link_msg.body =~ "Build the X feature"
    end

    test "captures recent links in transfer", ctx do
      assert {:ok, link_msg} = Transfer.create(ctx.ghost.id)

      # Should include mention of sent messages
      assert link_msg.body =~ "progress"
      # Should include mention of received messages
      assert link_msg.body =~ "guidance"
    end

    test "returns error for non-existent ghost" do
      assert {:error, :bee_not_found} = Transfer.create("ghost-nonexistent")
    end
  end

  describe "detect_handoff/1" do
    test "detects an unread transfer link_msg", ctx do
      {:ok, _waggle} = Transfer.create(ctx.ghost.id)

      assert {:ok, detected} = Transfer.detect_handoff(ctx.ghost.id)
      assert detected.subject == "transfer"
      assert detected.read == false
    end

    test "returns error when no transfer exists", ctx do
      assert {:error, :no_handoff} = Transfer.detect_handoff(ctx.ghost.id)
    end

    test "does not detect read transfers", ctx do
      {:ok, link_msg} = Transfer.create(ctx.ghost.id)
      GiTF.Link.mark_read(link_msg.id)

      assert {:error, :no_handoff} = Transfer.detect_handoff(ctx.ghost.id)
    end
  end

  describe "resume/2" do
    test "reads transfer and returns a briefing", ctx do
      {:ok, link_msg} = Transfer.create(ctx.ghost.id)

      assert {:ok, briefing} = Transfer.resume(ctx.ghost.id, link_msg.id)

      assert briefing =~ "Transfer Briefing"
      assert briefing =~ "continuing work"
      assert briefing =~ "Transfer Context"
    end

    test "marks the transfer link_msg as read", ctx do
      {:ok, link_msg} = Transfer.create(ctx.ghost.id)
      assert link_msg.read == false

      {:ok, _briefing} = Transfer.resume(ctx.ghost.id, link_msg.id)

      updated = Archive.get(:links, link_msg.id)
      assert updated.read == true
    end

    test "returns error for non-existent link_msg" do
      assert {:error, :transfer_not_found} = Transfer.resume("ghost-123", "lnk-nonexistent")
    end
  end

  describe "create/2 with session_id" do
    test "includes session_id section in transfer body", ctx do
      assert {:ok, link_msg} = Transfer.create(ctx.ghost.id, session_id: "sess-abc123")

      assert link_msg.body =~ "## Session ID"
      assert link_msg.body =~ "sess-abc123"
    end

    test "omits session_id section when not provided", ctx do
      assert {:ok, link_msg} = Transfer.create(ctx.ghost.id)

      refute link_msg.body =~ "## Session ID"
    end
  end

  describe "extract_session_id/1" do
    test "extracts session_id from transfer body" do
      body = """
      # Transfer Context
      Some content here.

      ## Session ID
      sess-abc123
      """

      assert "sess-abc123" = Transfer.extract_session_id(body)
    end

    test "returns nil for body without session_id" do
      body = """
      # Transfer Context
      Some content here.
      No session ID section.
      """

      assert nil == Transfer.extract_session_id(body)
    end

    test "returns nil for nil body" do
      assert nil == Transfer.extract_session_id(nil)
    end

    test "trims whitespace from extracted session_id" do
      body = "## Session ID\n  sess-with-spaces  \n"

      assert "sess-with-spaces" = Transfer.extract_session_id(body)
    end
  end

  describe "build_handoff_context/1" do
    test "builds markdown with all sections", ctx do
      assert {:ok, markdown} = Transfer.build_handoff_context(ctx.ghost.id)

      # Check all sections are present
      assert markdown =~ "# Transfer Context"
      assert markdown =~ "## Ghost Status"
      assert markdown =~ "## Job"
      assert markdown =~ "## Workspace"
      assert markdown =~ "## Recent Messages Sent"
      assert markdown =~ "## Recent Messages Received"
      assert markdown =~ "## Instructions for Continuation"
    end

    test "handles ghost with no op" do
      {:ok, ghost} = Archive.insert(:ghosts, %{name: "jobless-ghost", status: "idle"})

      assert {:ok, markdown} = Transfer.build_handoff_context(ghost.id)
      assert markdown =~ "No op assigned"
    end

    test "handles ghost with no shell" do
      {:ok, ghost} = Archive.insert(:ghosts, %{name: "cellless-ghost", status: "idle"})

      assert {:ok, markdown} = Transfer.build_handoff_context(ghost.id)
      assert markdown =~ "No workspace assigned"
    end

    test "returns error for non-existent ghost" do
      assert {:error, :bee_not_found} = Transfer.build_handoff_context("ghost-000000")
    end
  end
end
