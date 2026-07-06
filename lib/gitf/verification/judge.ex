defmodule GiTF.Verification.Judge do
  @moduledoc """
  LLM judge over a verification transcript.

  Given a holdout scenario's prose expectation and the transcript the driver
  captured, decides whether the observed behaviour satisfies the expectation.
  This is the "trust the gate, not the diff" step: the judge never sees the
  code, only what the artifact *did* when exercised through its real interface.
  """

  require Logger

  @doc """
  Judges `transcript` against `scenario`. Returns
  `{:pass, reasoning}` or `{:fail, reasoning}`. Any judge failure (LLM error,
  unparseable output) is fail-safe: `{:fail, reason}` — an unverifiable
  scenario must not count as passed.
  """
  @spec judge(GiTF.Verification.Driver.scenario(), GiTF.Verification.Driver.transcript()) ::
          {:pass, String.t()} | {:fail, String.t()}
  def judge(scenario, transcript) do
    prompt = build_prompt(scenario, transcript)

    case GiTF.Runtime.Models.generate_text(prompt, model: "haiku") do
      {:ok, output} -> parse(output)
      {:error, reason} -> {:fail, "judge LLM call failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:fail, "judge raised: #{Exception.message(e)}"}
  end

  defp build_prompt(scenario, transcript) do
    """
    # Behavioral Verification Judge

    You are judging whether a software change behaves correctly, based ONLY on
    what it did when exercised — not on its source code.

    ## Scenario
    #{scenario[:name]}

    ## Expected behaviour
    #{scenario[:expect]}

    ## Observed transcript
    ```
    #{String.slice(transcript[:text] || "", 0, 12_000)}
    ```

    Decide whether the observed behaviour satisfies the expected behaviour.
    Be strict: if the transcript does not clearly demonstrate the expectation,
    fail it. Respond with ONLY a JSON object:

    {"verdict": "pass" | "fail", "reasoning": "<one or two sentences>"}
    """
  end

  defp parse(output) do
    with {:ok, json} <- extract_json(output),
         verdict when verdict in ["pass", "fail"] <- json["verdict"] do
      reasoning = json["reasoning"] || ""

      case verdict do
        "pass" -> {:pass, reasoning}
        "fail" -> {:fail, reasoning}
      end
    else
      _ -> {:fail, "judge returned no parseable verdict"}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
