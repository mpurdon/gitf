defmodule GiTF.Flags do
  @moduledoc """
  Runtime feature flags via the config file — no restart required.

  A `[features]` table in the TOML config maps onto the boolean feature
  flags the codebase reads from Application env:

      [features]
      skills_enabled = true
      lsp_validation_enabled = true

  `GiTF.Config.Provider` calls `apply_from_config/1` every time config
  loads or reloads, so flipping a flag is: edit the config (Settings
  page or file), reload — live. Precedence: a `[features]` entry wins
  over the `GITF_*_ENABLED` boot env var (env is read once at boot;
  this applies after and on every reload). Flags absent from the table
  are left untouched, so partial tables don't reset anything.

  Only whitelisted flags apply — the config file must not be able to
  set arbitrary application env. Keep this list in sync with the
  `boolean_flags` list in `config/runtime.exs` (the env-var side of the
  same stopgap; the full Flag Registry + CLI is still the end state).
  """

  require Logger

  @known [
    :triage_enabled,
    :skills_enabled,
    :skill_refinement_enabled,
    :skill_auto_commit_enabled,
    :outcomes_enabled,
    :outcome_refinement_enabled,
    :outcome_autonomy_tiers_enabled,
    :vault_writer_enabled,
    :knowledge_context_enabled,
    :knowledge_compile_enabled,
    :workflow_dsl_enabled,
    :workflow_inference_enabled,
    :lsp_enabled,
    :lsp_validation_enabled,
    :webhooks_enabled,
    :visual_capture_enabled,
    :sandbox_enabled,
    :sandbox_required,
    :log_stdout,
    :bedrock_prompt_cache
  ]

  @doc "The whitelisted flag names."
  @spec known() :: [atom()]
  def known, do: @known

  @doc """
  Applies the `[features]` table of a loaded config map to Application
  env. Returns the list of flags applied. Unknown or non-boolean
  entries are logged and skipped, never raised — a typo in the config
  file must not take the daemon down.
  """
  @spec apply_from_config(map()) :: [atom()]
  def apply_from_config(config) when is_map(config) do
    features = Map.get(config, :features) || %{}

    Enum.reduce(features, [], fn
      {key, value}, acc when key in @known and is_boolean(value) ->
        if Application.get_env(:gitf, key) != value do
          Application.put_env(:gitf, key, value)
          Logger.info("feature flag #{key} → #{value} (config [features])")
        end

        [key | acc]

      {key, value}, acc ->
        Logger.warning(
          "ignoring [features] entry #{inspect(key)} = #{inspect(value)} — " <>
            "unknown flag or non-boolean value"
        )

        acc
    end)
    |> Enum.reverse()
  end
end
