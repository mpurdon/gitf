defmodule Hive.Plugin.Model do
  @moduledoc """
  Behaviour for model provider plugins.

  Model plugins wrap AI providers (Claude, Copilot, Kimi, etc.) and provide
  a uniform interface for spawning interactive and headless sessions.

  ## Required callbacks

  - `name/0` — unique plugin identifier (e.g. `"claude"`)
  - `description/0` — human-readable description
  - `spawn_interactive/2` — launch an interactive terminal session
  - `spawn_headless/3` — launch a headless prompt-in/output-out session
  - `parse_output/1` — parse streaming output into structured events

  ## Optional callbacks

  - `find_executable/0` — locate the provider's CLI binary
  - `workspace_setup/2` — return provider-specific workspace config map (or nil)
  - `pricing/0` — return pricing table (USD per million tokens)
  - `capabilities/0` — list of supported capability atoms
  - `extract_costs/1` — extract cost data from parsed events
  - `extract_session_id/1` — extract session ID from parsed events (or nil)
  - `progress_from_events/1` — extract progress updates from parsed events
  - `detached_command/2` — build a shell command string for detached spawning
  """

  @type event :: map()

  # Required callbacks
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback spawn_interactive(cwd :: String.t(), opts :: keyword()) ::
              {:ok, port()} | {:error, term()}
  @callback spawn_headless(prompt :: String.t(), cwd :: String.t(), opts :: keyword()) ::
              {:ok, port()} | {:error, term()}
  @callback parse_output(data :: binary()) :: [event()]

  # Optional callbacks
  @callback find_executable() :: {:ok, String.t()} | {:error, :not_found}
  @callback workspace_setup(bee_or_queen :: String.t(), hive_root :: String.t()) :: map() | nil
  @callback pricing() :: %{
              String.t() => %{
                input: float(),
                output: float(),
                cache_read: float(),
                cache_write: float()
              }
            }
  @callback capabilities() :: [atom()]
  @callback extract_costs(events :: [event()]) :: [map()]
  @callback extract_session_id(events :: [event()]) :: String.t() | nil
  @callback progress_from_events(events :: [event()]) :: [
              %{tool: String.t() | nil, file: String.t() | nil, message: String.t()}
            ]
  @callback detached_command(prompt :: String.t(), opts :: keyword()) :: String.t()
  @callback list_available_models() :: [String.t()]
  @callback get_model_info(model :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback get_context_limit(model :: String.t()) :: {:ok, integer()} | {:error, term()}

  @optional_callbacks [
    find_executable: 0,
    workspace_setup: 2,
    pricing: 0,
    capabilities: 0,
    extract_costs: 1,
    extract_session_id: 1,
    progress_from_events: 1,
    detached_command: 2,
    list_available_models: 0,
    get_model_info: 1,
    get_context_limit: 1
  ]
end
