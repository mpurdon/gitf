defmodule GiTF.Intel.PromptContext do
  @moduledoc """
  Generates compact historical context blocks for phase prompt injection.

  Target: ≤500 tokens. Contains only actionable intelligence drawn from
  the sector's intelligence profile. Content is tailored per phase so
  each ghost sees what matters most for its job.

  At `:none` confidence returns `""`. At `:low` returns a minimal note.
  At `:medium`/`:high` returns the full context block.
  """

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns a compact historical context string for a sector+phase combination.

  Delegates to SectorProfile for the cached profile, then renders
  phase-appropriate context from it.
  """
  @spec for_phase(String.t() | nil, String.t()) :: String.t()
  def for_phase(nil, _phase), do: ""

  def for_phase(sector_id, phase) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)
    render_from_profile(profile, phase)
  rescue
    _ -> ""
  end

  @doc false
  def render_from_profile(%{confidence: :none}, _phase), do: ""

  def render_from_profile(%{prompt_context: ctx}, _phase) when is_binary(ctx) and ctx != "" do
    ctx
  end

  def render_from_profile(_, _phase), do: ""

  @doc """
  Renders context directly from profile components. Called by SectorProfile.compute/1
  during profile construction to pre-render the context string.
  """
  @spec render_context(map(), map(), non_neg_integer(), atom()) :: String.t()
  def render_context(_lessons, _model_data, _sample_count, :none), do: ""

  def render_context(_lessons, _model_data, sample_count, :low) do
    """
    ## Historical Context

    - This sector has #{sample_count} completed mission#{if sample_count != 1, do: "s"}.

    Use this for reference only. Do not mention it in your output.
    """
    |> String.trim()
  end

  def render_context(lessons, model_data, sample_count, _confidence) do
    sections = []

    # Quality baseline
    sections = add_quality_line(sections, lessons.quality_baseline, sample_count)

    # Common failures
    sections = add_failure_lines(sections, lessons.common_failures)

    # Risky patterns (key lessons)
    sections = add_risky_patterns(sections, lessons.risky_patterns)

    # Success factors
    sections = add_success_factors(sections, lessons.success_factors)

    # Model trends (declining models)
    sections = add_model_warnings(sections, model_data)

    # Post-merge outcomes (real-world signal)
    sections = add_merge_success(sections, Map.get(lessons, :merge_success_rate))

    if Enum.empty?(sections) do
      ""
    else
      lines = sections |> Enum.reverse() |> Enum.join("\n")

      """
      ## Historical Context for This Codebase

      #{lines}

      Use this context to inform your approach. Do not reference it in your output.
      """
      |> String.trim()
    end
  end

  # -- Private: Section Builders -----------------------------------------------

  defp add_quality_line(sections, %{avg: avg, median: median}, sample_count)
       when is_number(avg) do
    median_part = if is_number(median), do: ", median: #{round(median)}", else: ""

    [
      "- **Quality baseline**: Avg #{round(avg)}/100 across #{sample_count} missions#{median_part}"
      | sections
    ]
  end

  defp add_quality_line(sections, _, _), do: sections

  defp add_failure_lines(sections, failures) when length(failures) > 0 do
    top =
      failures
      |> Enum.take(3)
      |> Enum.map(fn f -> "#{f.type} (#{round(f.frequency * 100)}%)" end)
      |> Enum.join(", ")

    ["- **Common failures**: #{top}" | sections]
  end

  defp add_failure_lines(sections, _), do: sections

  defp add_risky_patterns(sections, patterns) when length(patterns) > 0 do
    lines =
      patterns
      |> Enum.take(3)
      |> Enum.map(&"- **Key lesson**: #{&1}")
      |> Enum.join("\n")

    [lines | sections]
  end

  defp add_risky_patterns(sections, _), do: sections

  defp add_merge_success(sections, %{rate: rate, sample_count: n, reverted_count: rev, trend: trend})
       when is_number(rate) and n > 0 do
    trend_part =
      case trend do
        :improving -> " (improving)"
        :declining -> " (declining)"
        _ -> ""
      end

    rev_part = if rev > 0, do: " — #{rev} reverted", else: ""

    [
      "- **Merge-success rate**: #{round(rate * 100)}% across #{n} shipped missions#{rev_part}#{trend_part}"
      | sections
    ]
  end

  defp add_merge_success(sections, _), do: sections

  defp add_success_factors(sections, factors) when length(factors) > 0 do
    top =
      factors
      |> Enum.take(3)
      |> Enum.map(fn
        %{factor: f, frequency: freq} ->
          "#{humanize_factor(f)} (#{round(freq * 100)}%)"

        other ->
          inspect(other)
      end)
      |> Enum.join(", ")

    ["- **Success factors**: #{top}" | sections]
  end

  defp add_success_factors(sections, _), do: sections

  defp add_model_warnings(sections, model_data) when map_size(model_data) > 0 do
    declining =
      model_data
      |> Enum.filter(fn {_model, data} -> data.trend == :declining end)
      |> Enum.map(fn {model, _data} -> model end)

    if declining != [] do
      [
        "- **Caution**: Model#{if length(declining) > 1, do: "s"} showing quality decline: #{Enum.join(declining, ", ")}"
        | sections
      ]
    else
      sections
    end
  end

  defp add_model_warnings(sections, _), do: sections

  # -- Private: Helpers --------------------------------------------------------

  defp humanize_factor(factor) when is_binary(factor) do
    factor
    |> String.replace("_", " ")
    |> String.replace(~r/^model /, "")
  end

  defp humanize_factor(factor), do: inspect(factor)
end
