defmodule GiTF.Cabinet.Prefs do
  @moduledoc """
  The two operator preferences the Console keeps: what counts as needing a
  person, and which filtered views have been given a name.

  Both are small, both are policy rather than data, and both belong to the
  Cabinet rather than to a browser — an operator who set them on a laptop
  should find them on a phone. Stored as one singleton record and one small
  collection, because that is all they need.

  ## Investigations

  An investigation is a name attached to a filter set. That is the honest 90%
  of the idea it comes from — a saved workspace for one question — and it costs
  almost nothing because filters already live in the URL. The remaining 10%
  (pinned evidence, notes, a question you return to over days) is a real build
  and is not pretended at here.
  """

  alias GiTF.Archive

  @prefs :cabinet_prefs
  @investigations :investigations
  @needs_id "needs"

  # Queued activations and failed hand-overs are the two things the Cabinet can
  # honestly say are waiting on a person. Questions and approvals belong to a
  # mission and live on the factory.
  @default_needs_kinds ~w(activation)

  @doc "Which event kinds surface as needing a person."
  @spec needs_kinds() :: [String.t()]
  def needs_kinds do
    case Archive.get(@prefs, @needs_id) do
      %{kinds: kinds} when is_list(kinds) -> kinds
      _ -> @default_needs_kinds
    end
  end

  @doc "Turns one kind on or off. Returns the new list."
  @spec toggle_needs_kind(String.t()) :: [String.t()]
  def toggle_needs_kind(kind) do
    current = needs_kinds()
    next = if kind in current, do: current -- [kind], else: current ++ [kind]

    Archive.put(@prefs, %{id: @needs_id, kinds: next, updated_at: DateTime.utc_now()})
    next
  end

  def default_needs_kinds, do: @default_needs_kinds

  @doc "Saved investigations, oldest first so the list is stable as you add to it."
  @spec investigations() :: [map()]
  def investigations do
    @investigations
    |> Archive.all()
    |> Enum.sort_by(&Map.get(&1, :inserted_at, DateTime.utc_now()), DateTime)
  end

  @doc """
  Names a filter set.

  Refuses a blank name and a duplicate one: two investigations called the same
  thing are indistinguishable in the rail, which is the only place they appear.
  """
  @spec save_investigation(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def save_investigation(name, query) do
    name = String.trim(name || "")

    cond do
      name == "" ->
        {:error, :blank_name}

      Enum.any?(investigations(), &(String.downcase(&1.name) == String.downcase(name))) ->
        {:error, :duplicate_name}

      true ->
        Archive.insert(@investigations, %{
          name: name,
          query: query,
          inserted_at: DateTime.utc_now()
        })
    end
  end

  @spec delete_investigation(String.t()) :: :ok
  def delete_investigation(id) do
    Archive.delete(@investigations, id)
    :ok
  end
end
