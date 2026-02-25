defmodule Hive.Ingestion.WatchdogTest do
  use ExUnit.Case

  alias Hive.Ingestion.Watchdog
  alias Hive.Store

  setup do
    # Create temp root
    root = Path.join(System.tmp_dir!(), "hive_ingest_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    
    # Initialize Store (needed for combs/quests)
    start_supervised!({Hive.Store, data_dir: Path.join(root, ".hive/store")})
    
    # Create a dummy comb so ingestion works
    Hive.Comb.add(root, name: "test-comb")
    
    # Start Watchdog
    start_supervised!({Watchdog, hive_root: root})
    
    inbox = Path.join([root, ".hive", "inbox"])
    archive = Path.join([root, ".hive", "archive"])
    
    on_exit(fn -> File.rm_rf!(root) end)
    
    {:ok, %{inbox: inbox, archive: archive}}
  end

  test "ingests markdown file as quest", %{inbox: inbox, archive: archive} do
    # 1. Create a work order
    file_path = Path.join(inbox, "fix_login_bug.md")
    content = "The login button is broken on mobile."
    File.write!(file_path, content)
    
    # 2. Trigger scan (or wait)
    send(Watchdog, :scan)
    
    # 3. Wait for processing
    # Give it a moment to process async
    Process.sleep(100)
    
    # 4. Verify Quest created
    quests = Store.all(:quests)
    assert length(quests) == 1
    quest = hd(quests)
    assert quest.name == "Fix login bug" # Title derived from filename
    assert quest.goal == content
    assert quest.source == "inbox:fix_login_bug.md"
    
    # 5. Verify file archived
    assert File.ls!(inbox) == []
    assert length(File.ls!(archive)) == 1
  end
end
