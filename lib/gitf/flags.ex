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

  # Name and one line on what it does; `known/0` derives from this so a
  # flag cannot be added without saying what it is for.
  @flags [
    triage_enabled: "Triage phase before research (skip flags for trivial goals)",
    skills_enabled: "Skill library injected into phase prompts",
    skill_refinement_enabled: "Refine skills from mission outcomes",
    skill_auto_commit_enabled: "Commit refined skills to the sector",
    outcomes_enabled: "Track PRs after publish: merged, reverted, changes requested",
    outcome_refinement_enabled: "Learn from tracked outcomes",
    outcome_autonomy_tiers_enabled: "Per-sector autonomy tier from outcome history",
    vault_writer_enabled: "Write the factory's wiki",
    knowledge_context_enabled: "Knowledge pages injected into phase prompts",
    knowledge_compile_enabled: "Compile knowledge pages from missions",
    workflow_dsl_enabled: "Drive missions from workflow templates",
    workflow_inference_enabled: "Infer a workflow per mission with an LLM",
    lsp_enabled: "Language servers for ghosts",
    lsp_validation_enabled: "LSP diagnostics as validation ground truth",
    webhooks_enabled: "Accept GitHub webhooks (PR review intake)",
    visual_capture_enabled: "Screenshots and mockup rendering",
    sandbox_enabled: "Run validation inside bubblewrap",
    sandbox_required: "Refuse to validate without a working sandbox",
    log_stdout: "Log to stdout as well as the journal",
    bedrock_prompt_cache: "Bedrock prompt caching",
    wire_enabled: "Wire notation in phase prompts (specs/WIRE.md)"
  ]

  @known Keyword.keys(@flags)

  @doc "The whitelisted flag names."
  @spec known() :: [atom()]
  def known, do: @known

  @doc "One line on what a flag does."
  @spec describe(atom()) :: String.t()
  def describe(flag), do: Keyword.get(@flags, flag, to_string(flag))

  @doc """
  The `[features]` table of a config map, atom-keyed, whatever shape the
  map arrived in: the provider atomizes keys, the settings page reads the
  TOML raw. One reader, so `apply_from_config/1` and `effective/1` cannot
  disagree about whether a flag is pinned.
  """
  @spec features_table(map()) :: %{atom() => term()}
  def features_table(config) when is_map(config) do
    (Map.get(config, :features) || Map.get(config, "features") || %{})
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  What each flag is right now and what the config pins it to: `{flag,
  value, pin}` with `pin` `true`/`false` from the [features] table or
  `nil` when the boot value (env var or default) decides.
  """
  @spec effective(map()) :: [{atom(), boolean() | nil, boolean() | nil}]
  def effective(config) when is_map(config) do
    features = features_table(config)

    Enum.map(@known, fn flag ->
      pin =
        case Map.get(features, flag) do
          v when is_boolean(v) -> v
          _ -> nil
        end

      {flag, Application.get_env(:gitf, flag), pin}
    end)
  end

  @doc """
  Applies the `[features]` table of a loaded config map to Application
  env. Returns the list of flags applied. Unknown or non-boolean
  entries are logged and skipped, never raised — a typo in the config
  file must not take the daemon down.
  """
  @spec apply_from_config(map()) :: [atom()]
  def apply_from_config(config) when is_map(config) do
    features = features_table(config)

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
