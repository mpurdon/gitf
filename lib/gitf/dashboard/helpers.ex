defmodule GiTF.Dashboard.Helpers do
  @moduledoc "Shared helper functions for dashboard LiveViews."

  use Phoenix.Component

  require GiTF.Ghost.Status, as: GhostStatus

  def status_badge("completed"), do: "badge-green"
  def status_badge("done"), do: "badge-green"
  def status_badge("active"), do: "badge-blue"
  def status_badge("running"), do: "badge-blue"
  def status_badge("assigned"), do: "badge-blue"
  def status_badge(GhostStatus.working()), do: "badge-green"
  def status_badge(GhostStatus.starting()), do: "badge-blue"
  def status_badge(GhostStatus.idle()), do: "badge-grey"
  def status_badge("paused"), do: "badge-yellow"
  def status_badge(GhostStatus.stopped()), do: "badge-grey"
  def status_badge(GhostStatus.crashed()), do: "badge-red"
  def status_badge("failed"), do: "badge-red"
  def status_badge("blocked"), do: "badge-yellow"
  def status_badge("pending"), do: "badge-grey"
  def status_badge(_), do: "badge-grey"

  def phase_badge("research"), do: "badge-blue"
  def phase_badge("requirements"), do: "badge-blue"
  def phase_badge("design"), do: "badge-yellow"
  def phase_badge("review"), do: "badge-yellow"
  def phase_badge("planning"), do: "badge-yellow"
  def phase_badge("implementation"), do: "badge-purple"
  def phase_badge("validation"), do: "badge-purple"
  def phase_badge("awaiting_approval"), do: "badge-yellow"
  def phase_badge("sync"), do: "badge-blue"
  def phase_badge("simplify"), do: "badge-purple"
  def phase_badge("scoring"), do: "badge-blue"
  def phase_badge("completed"), do: "badge-green"
  def phase_badge(_), do: "badge-grey"

  def verification_badge("passed"), do: "badge-green"
  def verification_badge("failed"), do: "badge-red"
  def verification_badge("pending"), do: "badge-yellow"
  def verification_badge(_), do: "badge-grey"

  def format_cost(cost) when is_float(cost), do: "$#{:erlang.float_to_binary(cost, decimals: 4)}"

  def format_cost(cost) when is_integer(cost),
    do: "$#{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"

  def format_cost(_), do: "$0.0000"

  def format_tokens(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M"
  def format_tokens(count) when count >= 1_000, do: "#{Float.round(count / 1_000, 1)}K"
  def format_tokens(count), do: "#{count}"

  def format_timestamp(nil), do: "-"

  def format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def format_timestamp(_), do: "-"

  def short_id(nil), do: "-"
  def short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  def short_id(id), do: id

  def failure_type_badge(:compilation_error), do: "badge-red"
  def failure_type_badge(:context_overflow), do: "badge-orange"
  def failure_type_badge(:timeout), do: "badge-orange"
  def failure_type_badge(:ghost_crash), do: "badge-red"
  def failure_type_badge(:test_failure), do: "badge-yellow"
  def failure_type_badge(:audit_failure), do: "badge-yellow"
  def failure_type_badge(_), do: "badge-grey"

  def strategy_label(:simplify_scope), do: "Simplify Scope"
  def strategy_label(:different_model), do: "Different Model"
  def strategy_label(:increase_context), do: "Increase Context"
  def strategy_label(:fresh_start), do: "Fresh Start"
  def strategy_label(:split_task), do: "Split Task"
  def strategy_label(strategy) when is_atom(strategy), do: strategy |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  def strategy_label(strategy) when is_binary(strategy), do: String.capitalize(strategy)
  def strategy_label(strategy), do: "#{strategy}"

  @doc "Maps design strategy name to badge color suffix."
  def design_strategy_badge("minimal"), do: "blue"
  def design_strategy_badge("normal"), do: "green"
  def design_strategy_badge("complex"), do: "purple"
  def design_strategy_badge(_), do: "grey"

  @doc "Safely gets a list from a map key, returning [] on nil/missing."
  def get_list(nil, _key), do: []
  def get_list(map, key) when is_map(map), do: Map.get(map, key, []) |> List.wrap()
  def get_list(_, _), do: []

  @doc "Counts unique files across design components."
  def count_design_files(design) do
    get_list(design, "components")
    |> Enum.flat_map(&(Map.get(&1, "files", []) |> List.wrap()))
    |> Enum.uniq()
    |> length()
  end

  @doc "Sorts review issues by severity (high > medium > low)."
  def sort_issues(issues) do
    order = %{"high" => 0, "medium" => 1, "low" => 2}
    Enum.sort_by(issues, &Map.get(order, &1["severity"], 3))
  end

  @doc "Toggles membership in a MapSet."
  def toggle_set(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  @doc "Returns a status icon character for op status."
  def status_icon("done"), do: "✓"
  def status_icon("running"), do: "◐"
  def status_icon("assigned"), do: "◐"
  def status_icon("failed"), do: "✗"
  def status_icon("blocked"), do: "⊘"
  def status_icon(_), do: "○"

  @doc "Parses a model string into {provider, short_name, tier} for display."
  def parse_model(nil), do: {nil, nil, nil}
  def parse_model(model) when is_binary(model) do
    {provider, model_id} =
      case String.split(model, ":", parts: 2) do
        [p, m] -> {p, m}
        [m] -> {nil, m}
      end

    tier = infer_tier(model_id)
    short = shorten_model(model_id)
    {provider, short, tier}
  end

  @doc "Returns CSS class for provider-colored badge."
  def provider_class("google"), do: "model-google"
  def provider_class("anthropic"), do: "model-anthropic"
  def provider_class("openai"), do: "model-openai"
  def provider_class("ollama"), do: "model-ollama"
  def provider_class("bedrock"), do: "model-bedrock"
  def provider_class(_), do: "model-unknown"

  @doc "Returns tier glyph."
  def tier_glyph("thinking"), do: "🧠"
  def tier_glyph("fast"), do: "⚡"
  def tier_glyph(_), do: "◈"

  @doc "Returns a single combined badge: tier icon + ghost name, colored by provider."
  def ghost_badge_label(ghost_name, model) do
    {_provider, _short, tier} = parse_model(model)
    "#{tier_glyph(tier)} #{ghost_name}"
  end

  defp infer_tier(model) do
    m = String.downcase(model || "")
    cond do
      String.contains?(m, "opus") -> "thinking"
      String.contains?(m, "pro") and not String.contains?(m, "provision") -> "thinking"
      String.contains?(m, "flash") -> "fast"
      String.contains?(m, "haiku") -> "fast"
      true -> "general"
    end
  end

  defp shorten_model(nil), do: "-"
  defp shorten_model(model) do
    model
    |> String.replace(~r/^(gemini|claude)-/, "")
    |> String.replace(~r/-\d{8}.*$/, "")
    |> String.replace(~r/-v\d+:\d+$/, "")
  end

  @doc "Returns the CSS class suffix for an op status icon."
  def status_icon_class("done"), do: "done"
  def status_icon_class("running"), do: "running"
  def status_icon_class("assigned"), do: "running"
  def status_icon_class("failed"), do: "failed"
  def status_icon_class("blocked"), do: "blocked"
  def status_icon_class(_), do: "pending"
end
