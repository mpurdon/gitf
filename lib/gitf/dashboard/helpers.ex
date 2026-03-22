defmodule GiTF.Dashboard.Helpers do
  @moduledoc "Shared helper functions for dashboard LiveViews."

  use Phoenix.Component

  def status_badge("completed"), do: "badge-green"
  def status_badge("done"), do: "badge-green"
  def status_badge("active"), do: "badge-blue"
  def status_badge("running"), do: "badge-blue"
  def status_badge("assigned"), do: "badge-blue"
  def status_badge("working"), do: "badge-green"
  def status_badge("starting"), do: "badge-blue"
  def status_badge("idle"), do: "badge-grey"
  def status_badge("paused"), do: "badge-yellow"
  def status_badge("stopped"), do: "badge-grey"
  def status_badge("crashed"), do: "badge-red"
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
  def strategy_label(strategy), do: "#{strategy}"
end
