defmodule GiTF.Knowledge.CompileTest do
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Knowledge.{Compile, Index, Page}

  defmodule MockLLM do
    @behaviour GiTF.Runtime.LLMClient

    @impl true
    def generate_text(_model, _messages, _opts) do
      payload = Process.get(:mock_llm_payload, ~s({"pages": [], "index_updates": []}))
      {:ok, %{message: %{content: [%{text: payload}]}}}
    end
  end

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "knowledge-compile-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    prior_llm = Application.get_env(:gitf, :llm_client)
    prior_enabled = Application.get_env(:gitf, :knowledge_compile_enabled)

    System.put_env("GITF_PATH", gitf_root)
    Application.put_env(:gitf, :llm_client, MockLLM)
    Application.put_env(:gitf, :knowledge_compile_enabled, true)

    on_exit(fn ->
      if prior_path, do: System.put_env("GITF_PATH", prior_path), else: System.delete_env("GITF_PATH")
      if prior_llm, do: Application.put_env(:gitf, :llm_client, prior_llm), else: Application.delete_env(:gitf, :llm_client)

      if prior_enabled,
        do: Application.put_env(:gitf, :knowledge_compile_enabled, prior_enabled),
        else: Application.delete_env(:gitf, :knowledge_compile_enabled)

      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root}
  end

  defp mission(attrs \\ %{}) do
    Map.merge(
      %{
        id: "msn-c1",
        name: "Add OAuth2 refresh",
        goal: "Add OAuth2 refresh tokens with rotating refresh secrets.",
        sector_id: "fe",
        status: "completed",
        current_phase: "scoring",
        artifacts: %{}
      },
      attrs
    )
  end

  defp outcome(attrs \\ %{}) do
    Map.merge(%{mission_id: "msn-c1", pr_url: "https://github.com/x/y/pull/1"}, attrs)
  end

  defp set_llm_payload(payload), do: Process.put(:mock_llm_payload, payload)

  describe "compile_after_merge/2 — disabled" do
    test "is a no-op when feature flag is off" do
      Application.put_env(:gitf, :knowledge_compile_enabled, false)

      set_llm_payload(~s({"pages": [{"slug": "auth-flow", "title": "Auth Flow", "body": "x", "tags": []}]}))

      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert Page.get("fe", "auth-flow") == nil
    end
  end

  describe "compile_after_merge/2 — page application" do
    test "creates a page when LLM proposes one" do
      set_llm_payload(~s({
        "pages": [
          {"slug": "auth-flow", "title": "Auth Flow", "body": "OAuth2 with refresh.", "tags": ["auth"]}
        ],
        "index_updates": []
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())

      page = Page.get("fe", "auth-flow")
      assert page.title == "Auth Flow"
      assert page.tags == ["auth"]
      {:ok, body, _} = Page.read_body("fe", "auth-flow")
      assert body == "OAuth2 with refresh."
    end

    test "applies multiple pages in one mission" do
      set_llm_payload(~s({
        "pages": [
          {"slug": "auth-flow", "title": "Auth Flow", "body": "auth", "tags": []},
          {"slug": "token-rotation", "title": "Token Rotation", "body": "rotate", "tags": []}
        ],
        "index_updates": []
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert %{slug: "auth-flow"} = Page.get("fe", "auth-flow")
      assert %{slug: "token-rotation"} = Page.get("fe", "token-rotation")
    end

    test "is idempotent: re-running updates rather than duplicates" do
      payload = ~s({
        "pages": [{"slug": "auth-flow", "title": "Auth Flow", "body": "v1", "tags": []}],
        "index_updates": []
      })

      set_llm_payload(payload)
      assert :ok = Compile.compile_after_merge(mission(), outcome())

      payload2 = ~s({
        "pages": [{"slug": "auth-flow", "title": "Auth Flow", "body": "v2", "tags": []}],
        "index_updates": []
      })

      set_llm_payload(payload2)
      assert :ok = Compile.compile_after_merge(mission(), outcome())

      {:ok, body, _} = Page.read_body("fe", "auth-flow")
      assert body == "v2"
      assert length(Page.list("fe")) == 1
    end

    test "skips malformed page entries" do
      set_llm_payload(~s({
        "pages": [
          {"slug": "good", "title": "Good", "body": "ok", "tags": []},
          {"title": "Missing slug, body"}
        ],
        "index_updates": []
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert %{slug: "good"} = Page.get("fe", "good")
      assert length(Page.list("fe")) == 1
    end
  end

  describe "compile_after_merge/2 — index updates" do
    test "appends an entry to an existing index" do
      {:ok, _idx} = Index.put(%{name: "API Endpoints", sector_id: "fe", body: "- [[existing]] — old"})

      set_llm_payload(~s({
        "pages": [{"slug": "auth-flow", "title": "Auth", "body": "x", "tags": []}],
        "index_updates": [
          {"name": "API Endpoints", "entry": {"slug": "auth-flow", "gloss": "OAuth2 refresh"}}
        ]
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())

      idx = Index.get("fe", "API Endpoints")
      slugs = idx.entries |> Enum.map(& &1.slug)
      assert "existing" in slugs
      assert "auth-flow" in slugs
    end

    test "is dedupe-safe: duplicate entry doesn't get re-appended" do
      {:ok, _} = Index.put(%{name: "API", sector_id: "fe", body: "- [[auth-flow]] — already"})

      set_llm_payload(~s({
        "pages": [],
        "index_updates": [
          {"name": "API", "entry": {"slug": "auth-flow", "gloss": "duplicate"}}
        ]
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())

      idx = Index.get("fe", "API")
      assert length(idx.entries) == 1
    end

    test "ignores updates targeting non-existent indexes" do
      set_llm_payload(~s({
        "pages": [],
        "index_updates": [
          {"name": "Phantom Index", "entry": {"slug": "x", "gloss": "y"}}
        ]
      }))

      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert Index.get("fe", "Phantom Index") == nil
    end
  end

  describe "compile_after_merge/2 — robustness" do
    test "tolerates missing sector_id" do
      assert :ok = Compile.compile_after_merge(mission(%{sector_id: nil}), outcome())
    end

    test "tolerates LLM returning empty arrays" do
      set_llm_payload(~s({"pages": [], "index_updates": []}))
      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert Page.list("fe") == []
    end

    test "tolerates LLM returning non-JSON text" do
      set_llm_payload("definitely not json")
      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert Page.list("fe") == []
    end

    test "tolerates LLM returning unexpected shape" do
      set_llm_payload(~s({"unrelated_field": "value"}))
      assert :ok = Compile.compile_after_merge(mission(), outcome())
      assert Page.list("fe") == []
    end
  end
end
