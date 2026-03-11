defmodule GiTF.WaggleTest do
  use ExUnit.Case, async: false

  alias GiTF.Waggle

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  describe "send/5" do
    test "persists a waggle message to the database" do
      assert {:ok, waggle} = Waggle.send("major", "ghost-abc123", "Do work", "Build the feature")

      assert waggle.from == "major"
      assert waggle.to == "ghost-abc123"
      assert waggle.subject == "Do work"
      assert waggle.body == "Build the feature"
      assert waggle.read == false
      assert String.starts_with?(waggle.id, "wag-")
    end

    test "accepts optional metadata" do
      assert {:ok, waggle} =
               Waggle.send("ghost-a", "major", "Done", "Finished", ~s({"pr": 42}))

      assert waggle.metadata == ~s({"pr": 42})
    end
  end

  describe "list/1" do
    test "returns all messages with no filters" do
      {:ok, _} = Waggle.send("major", "ghost-a", "Task 1", "Body 1")
      {:ok, _} = Waggle.send("major", "ghost-b", "Task 2", "Body 2")

      waggles = Waggle.list()
      assert length(waggles) == 2
    end

    test "filters by recipient" do
      {:ok, _} = Waggle.send("major", "ghost-a", "For A", "Body")
      {:ok, _} = Waggle.send("major", "ghost-b", "For B", "Body")

      waggles = Waggle.list(to: "ghost-a")
      assert length(waggles) == 1
      assert hd(waggles).to == "ghost-a"
    end

    test "filters by sender" do
      {:ok, _} = Waggle.send("major", "ghost-a", "From queen", "Body")
      {:ok, _} = Waggle.send("ghost-a", "major", "From ghost", "Body")

      waggles = Waggle.list(from: "major")
      assert length(waggles) == 1
      assert hd(waggles).from == "major"
    end

    test "filters by read status" do
      {:ok, w} = Waggle.send("major", "ghost-a", "Read me", "Body")
      {:ok, _} = Waggle.send("major", "ghost-b", "Unread", "Body")

      Waggle.mark_read(w.id)

      unread = Waggle.list(read: false)
      assert length(unread) == 1
      assert hd(unread).subject == "Unread"
    end
  end

  describe "list_unread/1" do
    test "returns only unread messages for a given recipient" do
      {:ok, w1} = Waggle.send("major", "ghost-a", "First", "Body")
      {:ok, _} = Waggle.send("major", "ghost-a", "Second", "Body")
      {:ok, _} = Waggle.send("major", "ghost-b", "Other", "Body")

      Waggle.mark_read(w1.id)

      unread = Waggle.list_unread("ghost-a")
      assert length(unread) == 1
      assert hd(unread).subject == "Second"
    end
  end

  describe "mark_read/1" do
    test "marks a message as read" do
      {:ok, waggle} = Waggle.send("major", "ghost-a", "Read me", "Body")
      assert waggle.read == false

      assert {:ok, updated} = Waggle.mark_read(waggle.id)
      assert updated.read == true
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Waggle.mark_read("wag-000000")
    end
  end
end

defmodule GiTF.Waggle.TopicTest do
  use ExUnit.Case, async: true

  # Topic building is a pure function -- no DB needed.

  alias GiTF.Waggle

  describe "topic/2" do
    test "builds queen topic" do
      assert Waggle.topic(:major, nil) == "link:major"
    end

    test "builds ghost topic with ID" do
      assert Waggle.topic(:ghost, "ghost-abc123") == "waggle:ghost:ghost-abc123"
    end

    test "builds comb topic with name" do
      assert Waggle.topic(:comb, "myproject") == "waggle:comb:myproject"
    end
  end
end
