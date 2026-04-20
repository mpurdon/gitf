defmodule GiTF.Skills do
  @moduledoc """
  Storage and lifecycle for the self-improving skill library.

  A **skill** is a markdown+YAML-frontmatter artifact (matching Claude Code's
  `.claude/skills/` format) that captures one specific, testable piece of
  expertise. Skills are scoped:

    * `:global` — cross-sector lessons (e.g., "always re-run lockfiles after
      package.json edits"). `sector_id` is `nil`.
    * `:sector` — project-specific patterns (e.g., "this Phoenix app is on
      LiveView 1.0, use `phx-hook` not `data-hook`"). `sector_id` is set.

  Before a ghost spawns, `GiTF.Skills.Retrieval` embeds the op's goal and
  retrieves the top-K matching skills, which `GiTF.Skills.Install` writes
  into the worktree's `.claude/skills/` directory so Claude Code discovers
  them. After validation runs, `GiTF.Skills.Refinement` (M2) attributes
  outcomes and proposes updates.

  This module is the storage layer only. Embedding, retrieval, install,
  and refinement live in submodules.
  """

  alias GiTF.Archive

  @collection :skills

  @type scope :: :global | :sector
  @type source :: :human | :auto_drafted | :auto_refined
  @type status :: :active | :archived

  @type t :: %{
          id: String.t(),
          scope: scope(),
          sector_id: nil | String.t(),
          name: String.t(),
          description: String.t(),
          trigger_terms: [String.t()],
          body: String.t(),
          embedding: nil | [float()],
          embedding_model: nil | String.t(),
          source: source(),
          status: status(),
          applied_count: non_neg_integer(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @required_fields [:name, :description, :body, :scope]

  @doc """
  Creates a new skill. Returns `{:ok, skill}` or `{:error, reason}`.

  Required attrs: `:name`, `:description`, `:body`, `:scope`.
  When `scope` is `:sector`, `:sector_id` is also required.

  Defaults: `source: :human`, `status: :active`, counts `0`,
  `embedding: nil`, `trigger_terms: []`.
  """
  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(attrs) do
    attrs = normalize_keys(attrs)

    with :ok <- validate_required(attrs),
         :ok <- validate_scope(attrs) do
      record =
        Map.merge(
          %{
            scope: :global,
            sector_id: nil,
            trigger_terms: [],
            embedding: nil,
            embedding_model: nil,
            source: :human,
            status: :active,
            applied_count: 0,
            success_count: 0,
            failure_count: 0
          },
          attrs
        )

      Archive.insert(@collection, record)
    end
  end

  @doc "Fetches a skill by ID. Returns the skill or `nil`."
  @spec get(String.t()) :: t() | nil
  def get(id), do: Archive.get(@collection, id)

  @doc """
  Updates a skill via atomic RMW. The closure receives the current skill
  and returns the updated map (or `{:ok, map}` / `{:error, reason}`).
  """
  @spec update(String.t(), (t() -> t() | {:ok, t()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def update(id, update_fn), do: Archive.update(@collection, id, update_fn)

  @doc "Deletes a skill by ID."
  @spec delete(String.t()) :: :ok
  def delete(id), do: Archive.delete(@collection, id)

  @doc "Returns all active global skills."
  @spec list_global() :: [t()]
  def list_global do
    Archive.filter(@collection, fn s ->
      s.scope == :global and s.status == :active
    end)
  end

  @doc "Returns all active skills scoped to the given sector."
  @spec list_for_sector(String.t()) :: [t()]
  def list_for_sector(sector_id) when is_binary(sector_id) do
    Archive.filter(@collection, fn s ->
      s.scope == :sector and s.sector_id == sector_id and s.status == :active
    end)
  end

  @doc """
  Returns the union of global skills and sector-specific skills for the
  given sector. The pool from which retrieval scores top-K candidates.
  """
  @spec candidates_for(String.t() | nil) :: [t()]
  def candidates_for(nil), do: list_global()

  def candidates_for(sector_id) when is_binary(sector_id) do
    list_global() ++ list_for_sector(sector_id)
  end

  @doc "Returns all skills regardless of status (for operator UI/hygiene)."
  @spec all() :: [t()]
  def all, do: Archive.all(@collection)

  @doc """
  Atomically increments `applied_count` on a skill. Used by `Skills.Install`
  when a skill is written into a worktree.
  """
  @spec bump_applied(String.t()) :: {:ok, t()} | {:error, term()}
  def bump_applied(id) do
    update(id, fn s ->
      Map.update(s, :applied_count, 1, &(&1 + 1))
    end)
  end

  @doc "Atomically increments `success_count` on a skill."
  @spec bump_success(String.t()) :: {:ok, t()} | {:error, term()}
  def bump_success(id) do
    update(id, fn s ->
      Map.update(s, :success_count, 1, &(&1 + 1))
    end)
  end

  @doc "Atomically increments `failure_count` on a skill."
  @spec bump_failure(String.t()) :: {:ok, t()} | {:error, term()}
  def bump_failure(id) do
    update(id, fn s ->
      Map.update(s, :failure_count, 1, &(&1 + 1))
    end)
  end

  # -- Private: validation -----------------------------------------------------

  defp normalize_keys(attrs) do
    for {k, v} <- attrs, into: %{} do
      {if(is_binary(k), do: String.to_existing_atom(k), else: k), v}
    end
  rescue
    ArgumentError -> attrs
  end

  defp validate_required(attrs) do
    missing = Enum.reject(@required_fields, &Map.has_key?(attrs, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp validate_scope(%{scope: :global}), do: :ok

  defp validate_scope(%{scope: :sector, sector_id: id}) when is_binary(id) and id != "",
    do: :ok

  defp validate_scope(%{scope: :sector}), do: {:error, {:missing_fields, [:sector_id]}}

  defp validate_scope(%{scope: other}), do: {:error, {:invalid_scope, other}}
end
