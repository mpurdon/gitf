defmodule GiTF.Skills.Critic do
  @moduledoc """
  Second-pass critic for auto-drafted or auto-refined skills.

  `GiTF.Skills.Refinement` proposes a skill (new draft or patch to an
  existing skill). Before that proposal lands in the Archive, the critic
  reviews it against three questions:

    1. **Generalizable** — is this a lesson future missions can reuse, or
       is it specific to the one failed mission (e.g., a bug name only
       that project would ever see)?
    2. **Actionable** — is the rule specific enough for a ghost to follow?
       "Write better code" is not; "always commit the lockfile when
       package.json changes" is.
    3. **Non-conflicting** — does this skill contradict an existing skill
       in the pool without explaining why?

  Returns `{:ok, :approve | :needs_revision | :reject, reason}` or
  `{:error, term}` on LLM failure. Callers treat `:needs_revision` and
  `:reject` as "don't commit"; the distinction is for telemetry and
  future auto-revision (out of scope for M2).

  Mockable via the existing `GiTF.Runtime.LLMClient` behaviour — the
  simulator's scripted mock supplies deterministic critic responses.
  """

  require Logger

  alias GiTF.Runtime.LLMClient

  @type verdict :: :approve | :needs_revision | :reject

  @doc """
  Reviews a proposed skill. Returns the critic's verdict.

  `proposal` is the candidate skill map (`:name`, `:description`,
  `:body`, `:scope`, `:source`). `existing_skills` are the current skills
  in the same scope pool, used for conflict detection.

  On LLM failure, returns `{:error, reason}` — callers should treat this
  as a soft reject (don't commit), not a hard error.
  """
  @spec review(map(), [map()]) ::
          {:ok, verdict(), String.t()} | {:error, term()}
  def review(proposal, existing_skills \\ []) do
    prompt = build_prompt(proposal, existing_skills)
    model = model()

    case LLMClient.generate_text(model, prompt, []) do
      {:ok, response} ->
        text = extract_text(response)
        parse_verdict(text)

      {:error, reason} ->
        Logger.warning("Skills.Critic LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Skills.Critic raised: #{Exception.message(e)}")
      {:error, {:exception, e}}
  end

  @doc "Returns the configured critic model."
  @spec model() :: String.t()
  def model do
    Application.get_env(:gitf, :skill_critic_model, "google:gemini-2.5-flash")
  end

  # -- Private -----------------------------------------------------------------

  defp build_prompt(proposal, existing_skills) do
    existing_summaries =
      existing_skills
      |> Enum.take(10)
      |> Enum.map(fn s -> "- #{s.name}: #{truncate(s.description, 200)}" end)
      |> Enum.join("\n")

    existing_block =
      if existing_summaries == "",
        do: "(none)",
        else: existing_summaries

    """
    You are a critic reviewing a proposed new skill for an LLM agent factory's
    skill library. Decide whether this skill should be added to the library.

    Apply three tests:

      1. **Generalizable** — will future missions benefit from this lesson,
         or is it specific to one mission/project that nobody else will hit?
      2. **Actionable** — is the rule specific enough for an agent to
         follow? Vague advice like "write better code" is NOT actionable.
         Concrete rules like "when editing package.json, also commit the
         lockfile" ARE actionable.
      3. **Non-conflicting** — does this skill contradict an existing one
         without explaining why?

    Respond with ONLY a single line in this exact format:

        VERDICT: <approve|needs_revision|reject> | REASON: <one-sentence reason>

    No other output. No preamble.

    ## Proposed skill

    Name: #{proposal.name}
    Scope: #{proposal.scope}#{sector_line(proposal)}
    Source: #{proposal.source}

    Description:
    #{proposal.description}

    Body:
    ```
    #{truncate(proposal.body, 4000)}
    ```

    ## Existing skills in this pool

    #{existing_block}
    """
  end

  defp sector_line(%{scope: :sector, sector_id: id}) when is_binary(id),
    do: " (sector=#{id})"

  defp sector_line(_), do: ""

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: binary_part(str, 0, max) <> "..."

  defp extract_text(%{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{text: t} when is_binary(t) -> [t]
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  @verdict_pattern ~r/VERDICT:\s*(approve|needs_revision|reject)\s*\|\s*REASON:\s*(.+)/i

  defp parse_verdict(text) do
    case Regex.run(@verdict_pattern, text) do
      [_, verdict_str, reason] ->
        verdict = String.downcase(verdict_str) |> String.to_existing_atom()
        {:ok, verdict, String.trim(reason)}

      _ ->
        Logger.warning("Skills.Critic could not parse verdict from: #{inspect(text)}")
        {:error, {:unparseable_response, text}}
    end
  rescue
    ArgumentError ->
      {:error, {:unparseable_verdict, text}}
  end
end
