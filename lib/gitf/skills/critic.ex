defmodule GiTF.Skills.Critic do
  @moduledoc """
  Second-pass critic for auto-drafted/refined skills.

  Returns `{:ok, :approve | :needs_revision | :reject, reason}` or
  `{:error, term}`. Callers treat anything but `:approve` as "don't commit".
  Mockable via the `GiTF.Runtime.LLMClient` behaviour.
  """

  require Logger

  alias GiTF.Skills.LLM

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

    case LLM.generate_and_extract(model(), prompt) do
      {:ok, text} ->
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
      |> Enum.map(fn s -> "- #{s.name}: #{LLM.truncate(s.description, 200)}" end)
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
    #{LLM.truncate(proposal.body, 4000)}
    ```

    ## Existing skills in this pool

    #{existing_block}
    """
  end

  defp sector_line(%{scope: :sector, sector_id: id}) when is_binary(id),
    do: " (sector=#{id})"

  defp sector_line(_), do: ""

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
