defmodule GiTF.LinkTest do
  use GiTF.StoreCase

  alias GiTF.Link

  describe "send/5" do
    test "persists a link_msg message to the database" do
      assert {:ok, link_msg} = Link.send("major", "ghost-abc123", "Do work", "Build the feature")

      assert link_msg.from == "major"
      assert link_msg.to == "ghost-abc123"
      assert link_msg.subject == "Do work"
      assert link_msg.body == "Build the feature"
      assert link_msg.read == false
      assert String.starts_with?(link_msg.id, "lnk-")
    end

    test "accepts optional metadata" do
      assert {:ok, link_msg} =
               Link.send("ghost-a", "major", "Done", "Finished", ~s({"pr": 42}))

      assert link_msg.metadata == ~s({"pr": 42})
    end
  end

  describe "list/1" do
    test "returns all messages with no filters" do
      {:ok, _} = Link.send("major", "ghost-a", "Task 1", "Body 1")
      {:ok, _} = Link.send("major", "ghost-b", "Task 2", "Body 2")

      links = Link.list()
      assert length(links) == 2
    end

    test "filters by recipient" do
      {:ok, _} = Link.send("major", "ghost-a", "For A", "Body")
      {:ok, _} = Link.send("major", "ghost-b", "For B", "Body")

      links = Link.list(to: "ghost-a")
      assert length(links) == 1
      assert hd(links).to == "ghost-a"
    end

    test "filters by sender" do
      {:ok, _} = Link.send("major", "ghost-a", "From queen", "Body")
      {:ok, _} = Link.send("ghost-a", "major", "From ghost", "Body")

      links = Link.list(from: "major")
      assert length(links) == 1
      assert hd(links).from == "major"
    end

    test "filters by read status" do
      {:ok, w} = Link.send("major", "ghost-a", "Read me", "Body")
      {:ok, _} = Link.send("major", "ghost-b", "Unread", "Body")

      Link.mark_read(w.id)

      unread = Link.list(read: false)
      assert length(unread) == 1
      assert hd(unread).subject == "Unread"
    end
  end

  describe "list_unread/1" do
    test "returns only unread messages for a given recipient" do
      {:ok, w1} = Link.send("major", "ghost-a", "First", "Body")
      {:ok, _} = Link.send("major", "ghost-a", "Second", "Body")
      {:ok, _} = Link.send("major", "ghost-b", "Other", "Body")

      Link.mark_read(w1.id)

      unread = Link.list_unread("ghost-a")
      assert length(unread) == 1
      assert hd(unread).subject == "Second"
    end
  end

  describe "mark_read/1" do
    test "marks a message as read" do
      {:ok, link_msg} = Link.send("major", "ghost-a", "Read me", "Body")
      assert link_msg.read == false

      assert {:ok, updated} = Link.mark_read(link_msg.id)
      assert updated.read == true
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Link.mark_read("lnk-000000")
    end
  end
end

defmodule GiTF.Link.TopicTest do
  use ExUnit.Case, async: true

  # Topic building is a pure function -- no DB needed.

  alias GiTF.Link

  describe "topic/2" do
    test "builds queen topic" do
      assert Link.topic(:major, nil) == "link:major"
    end

    test "builds ghost topic with ID" do
      assert Link.topic(:ghost, "ghost-abc123") == "link_msg:ghost:ghost-abc123"
    end

    test "builds sector topic with name" do
      assert Link.topic(:sector, "myproject") == "link_msg:sector:myproject"
    end
  end
end
