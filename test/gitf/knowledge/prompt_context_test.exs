defmodule GiTF.Knowledge.PromptContextTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.{Index, Page, PromptContext}

  defmodule MockClient do
    @behaviour GiTF.Skills.Embedding

    @impl true
    def embed(_model, text) do
      keywords = ["auth", "billing", "search"]
      down = String.downcase(text)
      vec = for kw <- keywords, do: if(String.contains?(down, kw), do: 1.0, else: 0.0)
      vec = if Enum.all?(vec, &(&1 == 0.0)), do: [0.001, 0.001, 0.001], else: vec
      {:ok, vec}
    end
  end

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "knowledge-prompt-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    prior_client = Application.get_env(:gitf, :embedding_client)
    prior_enabled = Application.get_env(:gitf, :knowledge_context_enabled)

    System.put_env("GITF_PATH", gitf_root)
    Application.put_env(:gitf, :embedding_client, MockClient)
    Application.put_env(:gitf, :knowledge_context_enabled, true)

    on_exit(fn ->
      if prior_path,
        do: System.put_env("GITF_PATH", prior_path),
        else: System.delete_env("GITF_PATH")

      if prior_client,
        do: Application.put_env(:gitf, :embedding_client, prior_client),
        else: Application.delete_env(:gitf, :embedding_client)

      if prior_enabled,
        do: Application.put_env(:gitf, :knowledge_context_enabled, prior_enabled),
        else: Application.delete_env(:gitf, :knowledge_context_enabled)

      File.rm_rf!(gitf_root)
    end)

    %{gitf_root: gitf_root}
  end

  describe "for_mission/3" do
    test "returns empty when feature flag is off" do
      Application.put_env(:gitf, :knowledge_context_enabled, false)

      {:ok, _} = Page.put(%{slug: "auth", sector_id: "fe", body: "auth login flow"})

      assert PromptContext.for_mission("fe", %{goal: "fix auth"}) == ""
    end

    test "returns empty when sector is nil" do
      assert PromptContext.for_mission(nil, %{goal: "anything"}) == ""
    end

    test "returns empty when no pages or indexes exist" do
      assert PromptContext.for_mission("empty-sector", %{goal: "anything"}) == ""
    end

    test "renders an Indexes section listing each curated TOC" do
      {:ok, _} = Index.put(%{name: "API Endpoints", sector_id: "fe", body: "- [[a]]\n- [[b]]"})

      {:ok, _} =
        Index.put(%{name: "Glossary", sector_id: "fe", body: "- [[term1]]", kind: :glossary})

      out = PromptContext.for_mission("fe", %{goal: "anything"})

      assert out =~ "## Knowledge"
      assert out =~ "### Indexes"
      assert out =~ "001_API Endpoints"
      assert out =~ "002_Glossary"
      assert out =~ "2 entries"
      assert out =~ "1 entry"
    end

    test "renders a Likely-relevant pages section using semantic search" do
      {:ok, _} =
        Page.put(%{
          slug: "auth-flow",
          sector_id: "fe",
          title: "Auth Flow",
          body: "auth login session"
        })

      {:ok, _} =
        Page.put(%{
          slug: "billing-overview",
          sector_id: "fe",
          title: "Billing",
          body: "billing invoices"
        })

      out = PromptContext.for_mission("fe", %{goal: "investigate auth bug"}, top_k: 1)

      assert out =~ "### Likely-relevant pages"
      assert out =~ "[[auth-flow]] (Auth Flow)"
      refute out =~ "[[billing-overview]]"
    end

    test "extracts a one-line gloss from the page body" do
      body = """
      # Auth Flow

      The login flow uses short-lived tokens with refresh on 401.

      Further details below.
      """

      {:ok, _} = Page.put(%{slug: "auth-flow", sector_id: "fe", title: "Auth Flow", body: body})

      out = PromptContext.for_mission("fe", %{goal: "auth question"}, top_k: 1)

      assert out =~ "The login flow uses short-lived tokens"
    end

    test "respects max_chars by truncating output" do
      for n <- 1..30 do
        {:ok, _} =
          Page.put(%{
            slug: "auth-#{n}",
            sector_id: "fe",
            title: "Auth #{n}",
            body: "auth content #{n} #{String.duplicate("x ", 100)}"
          })
      end

      out = PromptContext.for_mission("fe", %{goal: "auth"}, top_k: 30, max_chars: 200)

      assert byte_size(out) <= 230
      assert out =~ "_(truncated)_"
    end

    test "header references the file convention" do
      {:ok, _} = Page.put(%{slug: "auth", sector_id: "fe", title: "Auth", body: "auth"})
      out = PromptContext.for_mission("fe", %{goal: "auth"}, top_k: 1)
      assert out =~ "Sectors/<sector>/Pages/<slug>.md"
    end
  end

  describe "for_phase/4" do
    test "delegates to for_mission/3" do
      {:ok, _} = Page.put(%{slug: "auth", sector_id: "fe", title: "Auth", body: "auth"})
      out = PromptContext.for_phase("fe", "research", %{goal: "auth"}, top_k: 1)
      assert out =~ "[[auth]]"
    end
  end
end
