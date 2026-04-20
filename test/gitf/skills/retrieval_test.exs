defmodule GiTF.Skills.RetrievalTest do
  use ExUnit.Case, async: false

  alias GiTF.Skills
  alias GiTF.Skills.Retrieval

  defmodule MockClient do
    @behaviour GiTF.Skills.Embedding

    @impl true
    def embed(_model, text) do
      # Simple bag-of-keywords vector: 4 dims for ["lockfile", "evidence", "reuse", "commit"]
      keywords = ["lockfile", "evidence", "reuse", "commit"]
      down = String.downcase(text)
      vec = for kw <- keywords, do: if(String.contains?(down, kw), do: 1.0, else: 0.0)
      # Add tiny epsilon so all-zero vectors don't break cosine
      vec = if Enum.all?(vec, &(&1 == 0.0)), do: [0.001, 0.001, 0.001, 0.001], else: vec
      {:ok, vec}
    end
  end

  setup do
    GiTF.Archive.all(:skills)
    |> Enum.each(fn s -> GiTF.Archive.delete(:skills, s.id) end)

    prev = Application.get_env(:gitf, :embedding_client)
    Application.put_env(:gitf, :embedding_client, MockClient)
    on_exit(fn ->
      if prev,
        do: Application.put_env(:gitf, :embedding_client, prev),
        else: Application.delete_env(:gitf, :embedding_client)
    end)

    {:ok, _lf} =
      Skills.create(%{
        name: "lockfile-rule",
        description: "After package.json changes, regenerate the lockfile",
        body: "rule about lockfile",
        scope: :global
      })

    {:ok, _ev} =
      Skills.create(%{
        name: "evidence-rule",
        description: "Validator evidence must cite file:line",
        body: "rule about evidence",
        scope: :global
      })

    {:ok, _reuse} =
      Skills.create(%{
        name: "reuse-rule",
        description: "Prefer existing utilities — don't reuse-and-rewrite",
        body: "rule about reuse",
        scope: :global
      })

    :ok
  end

  describe "retrieve/3" do
    test "matches op goal to most relevant skill" do
      op = %{
        title: "Update package.json dependencies",
        description: "Bump react to v19 and ensure the lockfile is committed"
      }

      assert {:ok, skills} = Retrieval.retrieve(op, nil, top_k: 1, min_similarity: 0.0)
      assert length(skills) == 1
      assert hd(skills).name == "lockfile-rule"
    end

    test "returns empty list when no skills match above threshold" do
      op = %{title: "Unrelated", description: "Nothing matches our keywords"}

      # Skills' keyword vectors are unit-aligned to single axes; the fallback
      # all-equal query vector has cosine ~0.5 against them, so a 0.99
      # threshold filters them all out.
      assert {:ok, []} = Retrieval.retrieve(op, nil, top_k: 5, min_similarity: 0.99)
    end

    test "respects top_k limit" do
      op = %{
        title: "lockfile evidence reuse commit",
        description: "all keywords"
      }

      assert {:ok, skills} = Retrieval.retrieve(op, nil, top_k: 2, min_similarity: 0.0)
      assert length(skills) == 2
    end

    test "includes sector skills for the given sector" do
      {:ok, sector_skill} =
        Skills.create(%{
          name: "sector-evidence",
          description: "evidence stuff in this sector",
          body: "b",
          scope: :sector,
          sector_id: "sec-XYZ"
        })

      op = %{title: "evidence work", description: "evidence things"}

      {:ok, skills} = Retrieval.retrieve(op, "sec-XYZ", top_k: 5, min_similarity: 0.0)
      ids = Enum.map(skills, & &1.id)
      assert sector_skill.id in ids
    end

    test "returns {:ok, []} when embedding client errors" do
      defmodule FailingClient do
        @behaviour GiTF.Skills.Embedding
        @impl true
        def embed(_model, _text), do: {:error, :provider_down}
      end

      Application.put_env(:gitf, :embedding_client, FailingClient)
      op = %{title: "x", description: "y"}

      assert {:ok, []} = Retrieval.retrieve(op, nil)
    end
  end
end
