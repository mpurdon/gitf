defmodule GiTF.Cabinet.Discord.Grounding do
  @moduledoc """
  Did the persona only name things it actually looked up?

  Every write an agent proposes is confirmed by a human tap, so a bad write
  has a judge. A *read* has none — the operator asks "what's running", gets
  a sentence, and acts on it. An invented mission id in that sentence is
  the most damaging thing these personas can produce, because nothing
  downstream checks it.

  So: `GiTF.Cabinet.Discord.Toolbelt` records every factory id that appears
  in a tool *result*, and this module asserts the reply mentions no others.
  Deterministic, no second model call, and it catches the exact failure
  mode that matters — a hallucinated `msn-4f2a11` cannot be grounded
  because it never came back from a tool.

  What this does NOT catch, deliberately: a reply that cites real ids but
  characterises them wrongly ("looks fine" when validation failed). That
  needs an LLM judge, which is a separate decision with a real cost —
  `GiTF.Verification.Judge` and
  `GiTF.Runtime.CrossModelAudit.select_audit_model/1` are the machinery to
  reuse if it is ever wanted.

  A failure annotates rather than suppresses. A reply that is ninety
  percent right with one invented id is still worth showing, as long as the
  operator can see which part not to trust.
  """

  # Archive ids are `<prefix>-<6 hex>` (`GiTF.ID.generate/1`). Only the
  # prefixes an operator would act on are checked: a mission, an op, a
  # ghost, a question, a project. Sector and link ids are not things a
  # persona asks you to decide about.
  @prefixes ~w(msn op ghost inq prj)

  @id_pattern ~r/\b(?:#{Enum.join(@prefixes, "|")})-[0-9a-f]{6}\b/

  @doc "Every factory id mentioned in `text`, deduplicated."
  @spec ids(term()) :: MapSet.t()
  def ids(text) when is_binary(text) do
    @id_pattern
    |> Regex.scan(text)
    |> Enum.map(&List.first/1)
    |> MapSet.new()
  end

  def ids(_), do: MapSet.new()

  @doc """
  Checks `reply` against the ids that came back from tools.

  Returns `:ok`, or `{:ungrounded, [id]}` naming the ids the persona
  produced from nowhere.

  An empty grounded set is only a failure if the reply names ids anyway —
  a persona that answered from its system prompt without calling anything
  and cited no ids has invented nothing.
  """
  @spec check(String.t(), MapSet.t()) :: :ok | {:ungrounded, [String.t()]}
  def check(reply, grounded) do
    case reply |> ids() |> MapSet.difference(grounded) |> MapSet.to_list() do
      [] -> :ok
      invented -> {:ungrounded, Enum.sort(invented)}
    end
  end

  @doc """
  The reply as the operator should see it: unchanged when grounded, with a
  visible warning appended when not.

  Named ids are listed so the operator knows exactly which claim to
  distrust, rather than being told the whole answer is suspect.
  """
  @spec annotate(String.t(), MapSet.t()) :: {String.t(), :ok | {:ungrounded, [String.t()]}}
  def annotate(reply, grounded) do
    case check(reply, grounded) do
      :ok ->
        {reply, :ok}

      {:ungrounded, invented} = verdict ->
        {reply <>
           "\n\n⚠ I mentioned " <>
           Enum.join(invented, ", ") <>
           " without looking " <>
           plural(invented) <> " up — treat " <> those(invented) <> " as unverified.", verdict}
    end
  end

  defp plural([_]), do: "it"
  defp plural(_), do: "them"

  defp those([_]), do: "that"
  defp those(_), do: "those"
end
