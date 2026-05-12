defmodule GiTF.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if GiTF.Client.remote?() do
      # Remote mode: thin client, no local services needed
      Supervisor.start_link([], strategy: :one_for_one, name: GiTF.Supervisor)
    else
      start_full_app()
    end
  end

  @impl true
  def prep_stop(state) do
    Logger.info("GiTF shutting down gracefully...")
    # Explicitly clean up the MCP socket + PID file.
    # This fires even when terminate/2 on the GenServer is skipped
    # (e.g. escript SIGINT, unclean shutdown).
    GiTF.MCPServer.SocketListener.cleanup()
    state
  end

  defp start_full_app do
    # Store boot timestamp for uptime tracking
    :persistent_term.put(:gitf_boot_time, System.system_time(:second))

    GiTF.Init.init_global()
    File.mkdir_p!(Path.join(GiTF.global_config_dir(), "llm_db"))

    # Determine project root for config overlay.
    # Resolution: GITF_PATH env → walk-up from cwd → homedir (~/.gitf)
    # Homedir is the default for system-wide installs; walk-up is legacy
    # workspace-local mode.
    gitf_root =
      case GiTF.gitf_dir() do
        {:ok, root} -> root
        _ -> System.get_env("GITF_HOME") || System.user_home!()
      end

    # Derive store dir from gitf_root unless explicitly overridden (tests do this).
    store_dir = Application.get_env(:gitf, :store_dir, Path.join(gitf_root, ".gitf/store"))

    setup_file_logging()

    # Keys must load before any supervised child may use them
    GiTF.Runtime.Keys.load()

    if GiTF.Runtime.ModelResolver.ollama_mode?() do
      GiTF.Runtime.ModelResolver.setup_ollama_env()
    end

    # Set up AWS credentials for Bedrock if it's in the provider priority.
    # Wrapped — ProviderManager may not be ready yet in some envs.
    try do
      if "bedrock" in GiTF.Runtime.ProviderManager.provider_priority() do
        GiTF.Runtime.ProviderManager.ensure_aws_credentials()
      end
    rescue
      _ -> :ok
    end

    GiTF.Progress.init()
    GiTF.CircuitBreaker.init()
    GiTF.Observability.Metrics.init()
    # Telemetry handlers must be attached before children that emit events start
    GiTF.Telemetry.attach_default_handlers()
    GiTF.Observability.Metrics.attach_handlers()

    # -----------------------------------------------------------------------
    # Supervision tree — grouped by failure domain
    # -----------------------------------------------------------------------
    #
    # Foundation: PubSub, Archive, Registry, TaskSupervisor
    #   → Must start first, everything depends on these
    #
    # Core (rest_for_one): Major, SectorSupervisor, RateLimiter, Watchdogs
    #   → If Major crashes, ghosts/sectors restart too (they depend on Major)
    #
    # Interface (one_for_one): Endpoint, MCP socket, ViewModel, PubSubBridge
    #   → Dashboard/MCP crash never kills the factory
    #
    # Plugins (one_for_one): MCP plugins, channels, plugin manager
    #   → Isolated from everything else
    #
    # Background (one_for_one): Observability, Tachikoma, SyncQueue, Exfil, Cache
    #   → Optional services, skipped in test
    # -----------------------------------------------------------------------

    foundation = [
      GiTF.Readiness,
      {Phoenix.PubSub, name: GiTF.PubSub},
      # Config.Provider must start before Archive (migrations / Archive may read config)
      Supervisor.child_spec(
        {GiTF.Config.Provider, [gitf_root: gitf_root]},
        id: GiTF.Config.Provider
      ),
      # ETS heir must start before Archive so Archive's cache can be made recoverable
      GiTF.Archive.TableHeir,
      {GiTF.Archive, data_dir: store_dir},
      {Registry, keys: :unique, name: GiTF.Registry},
      {Task.Supervisor, name: GiTF.TaskSupervisor},
      # Deferred init — non-critical one-shot work under supervision. Runs after
      # Archive/Config.Provider are up. :transient so normal completion doesn't restart.
      Supervisor.child_spec(
        {Task, &__MODULE__.deferred_init/0},
        id: GiTF.DeferredInit,
        restart: :transient
      )
    ]

    core = %{
      id: GiTF.Core.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {GiTF.RateLimiter,
              name: GiTF.RateLimiter, max_tokens: 30, refill_rate: 30, refill_interval: 1_000},
             {DynamicSupervisor,
              name: GiTF.Runtime.ProviderLimiter.Supervisor, strategy: :one_for_one},
             {DynamicSupervisor, name: GiTF.MissionSupervisor, strategy: :one_for_one},
             {GiTF.Major, gitf_root: gitf_root},
             # Periodic recovery/stall/debrief timers — owned by a sibling so
             # Janitor crashes don't disrupt Major's link routing. Positioned
             # AFTER Major: under :rest_for_one a Janitor crash leaves Major
             # untouched, while a Major restart will also restart Janitor so
             # it re-acquires its read accessor cleanly.
             {GiTF.Major.Janitor, []},
             {GiTF.Outcomes.Tracker, []},
             {GiTF.LSP.Supervisor, []},
             {GiTF.SectorSupervisor, []},
             {GiTF.Budget.Watchdog, []},
             {GiTF.Vault.Writer, []},
             {GiTF.Ingestion.Watchdog, gitf_root: File.cwd!()}
           ],
           [
             strategy: :rest_for_one,
             name: GiTF.Core.Supervisor,
             max_restarts: 10,
             max_seconds: 30
           ]
         ]}
    }

    interface_children =
      endpoint_child() ++
        [
          {GiTF.MCPServer.SocketListener, []},
          {GiTF.ViewModel, []},
          {GiTF.PubSubBridge, []},
          # Graceful shutdown: drain in-flight HTTP requests before stopping
          # cowboy listeners. Must come after endpoints in the sibling list.
          {Plug.Cowboy.Drainer, refs: [GiTF.Web.Endpoint.HTTP]}
        ]

    interface = %{
      id: GiTF.Interface.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           interface_children,
           [strategy: :one_for_one, name: GiTF.Interface.Supervisor]
         ]}
    }

    plugins = %{
      id: GiTF.Plugin.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {GiTF.Plugin.MCPSupervisor, []},
             {GiTF.Plugin.ChannelSupervisor, []},
             {GiTF.Plugin.Manager, []}
           ],
           [strategy: :one_for_one, name: GiTF.Plugin.Supervisor]
         ]}
    }

    children = foundation ++ [core, interface, plugins] ++ background_children()

    opts = [strategy: :one_for_one, name: GiTF.Supervisor]
    result = Supervisor.start_link(children, opts)
    log_feature_flags()

    # Attach Vault.Writer telemetry handlers — idempotent and gated at
    # event time by `:vault_writer_enabled`, so this is safe even when
    # the operator hasn't opted in to the vault.
    GiTF.Vault.Writer.attach_telemetry()

    result
  end

  # Logs every known feature flag's effective value on startup so operators
  # can immediately confirm overrides (env vars, config) took effect. Will
  # be replaced by GiTF.Flags.Registry once the flag registry lands (see
  # plans/flag-registry.md).
  defp log_feature_flags do
    flags = [
      {:triage_enabled, "GITF_TRIAGE_ENABLED", false},
      {:skills_enabled, "GITF_SKILLS_ENABLED", false},
      {:skill_refinement_enabled, "GITF_SKILL_REFINEMENT_ENABLED", false},
      {:skill_auto_commit_enabled, "GITF_SKILL_AUTO_COMMIT_ENABLED", false},
      {:outcomes_enabled, "GITF_OUTCOMES_ENABLED", false},
      {:outcome_refinement_enabled, "GITF_OUTCOME_REFINEMENT_ENABLED", false},
      {:vault_writer_enabled, "GITF_VAULT_WRITER_ENABLED", false},
      {:knowledge_context_enabled, "GITF_KNOWLEDGE_CONTEXT_ENABLED", false},
      {:knowledge_compile_enabled, "GITF_KNOWLEDGE_COMPILE_ENABLED", false},
      {:workflow_dsl_enabled, "GITF_WORKFLOW_DSL_ENABLED", false},
      {:workflow_inference_enabled, "GITF_WORKFLOW_INFERENCE_ENABLED", false}
    ]

    lines =
      Enum.map(flags, fn {key, env_var, default} ->
        value = Application.get_env(:gitf, key, default)

        source =
          cond do
            env_var && System.get_env(env_var) not in [nil, ""] -> "env #{env_var}"
            value != default -> "config"
            true -> "default"
          end

        "  #{key}: #{inspect(value)} (#{source})"
      end)

    Logger.info("Factory feature flags:\n" <> Enum.join(lines, "\n"))
  end

  # Start the web endpoint, retrying briefly if the port is still releasing
  # from a previous Ctrl+C abort.
  defp endpoint_child do
    port = Application.get_env(:gitf, GiTF.Web.Endpoint)[:http][:port] || 4000
    try_bind_port(port, 3)
  end

  defp try_bind_port(_port, 0) do
    Logger.info("Port still in use after retries, skipping web endpoint.")
    []
  end

  defp try_bind_port(port, retries) do
    case :gen_tcp.listen(port, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        [{GiTF.Web.Endpoint, []}]

      {:error, :eaddrinuse} ->
        if retries > 1 do
          Logger.info("Port #{port} busy, waiting for release (#{retries - 1} retries left)...")
          Process.sleep(1000)
          try_bind_port(port, retries - 1)
        else
          Logger.info(
            "Port #{port} already in use, skipping web endpoint. " <>
              "A GiTF server may already be running."
          )

          []
        end

      {:error, :eacces} ->
        Logger.warning("Permission denied for port #{port}. Try a port above 1024.")
        []

      {:error, reason} ->
        Logger.warning("Cannot bind to port #{port}: #{inspect(reason)}. Skipping web endpoint.")
        []
    end
  end

  # Background services — skip in test to avoid conflicts
  defp background_children do
    bg = [
      {GiTF.Runtime.GeminiCacheManager, []},
      {GiTF.Exfil, []}
    ]

    optional =
      if function_exported?(Mix, :env, 0) and Mix.env() == :test do
        []
      else
        [
          {GiTF.Observability, []},
          {GiTF.Tachikoma, []},
          {GiTF.Sync.Queue, []},
          {GiTF.Ledger, []}
        ]
      end

    bg_children = bg ++ optional

    [
      %{
        id: GiTF.Background.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             bg_children,
             [
               strategy: :one_for_one,
               name: GiTF.Background.Supervisor,
               max_restarts: 5,
               max_seconds: 60
             ]
           ]}
      }
    ]
  end

  @doc """
  Non-critical init work run under supervision as a Task child, so it can't
  block boot and any crash is observed by the supervisor rather than taking
  down application start.
  """
  def deferred_init do
    # Push LLM timeout into ReqLLM's application env
    try do
      llm_timeout = GiTF.Config.Provider.get([:llm, :receive_timeout_ms]) || 60_000
      Application.put_env(:req_llm, :receive_timeout, llm_timeout)
    rescue
      e -> Logger.warning("deferred_init: llm timeout setup failed: #{inspect(e)}")
    end

    # Reset any stale circuit breaker state from a prior session
    try do
      GiTF.CircuitBreaker.reset("api:llm")
      for key <- GiTF.CircuitBreaker.list_open("llm:"), do: GiTF.CircuitBreaker.reset(key)
    rescue
      e -> Logger.warning("deferred_init: circuit breaker reset failed: #{inspect(e)}")
    end

    try do
      validate_config()
    rescue
      e -> Logger.warning("deferred_init: validate_config failed: #{inspect(e)}")
    end

    # Seed bootstrap skills (idempotent — skips entries already in Archive).
    try do
      GiTF.Skills.Bootstrap.seed_global_skills()
    rescue
      e -> Logger.warning("deferred_init: skill bootstrap failed: #{inspect(e)}")
    end

    :ok
  end

  defp validate_config do
    alias GiTF.Config.Provider

    warnings = []

    warnings =
      if Provider.get([:costs, :budget_usd]) == nil do
        ["costs.budget_usd not set (defaulting to $10)" | warnings]
      else
        warnings
      end

    warnings =
      if Provider.get([:major, :max_ghosts]) == nil do
        ["queen.max_ghosts not set (defaulting to 5)" | warnings]
      else
        warnings
      end

    warnings =
      if GiTF.Runtime.ModelResolver.api_mode?() do
        has_google = (Provider.get([:llm, :keys, :google]) || "") != ""
        has_anthropic = (Provider.get([:llm, :keys, :anthropic]) || "") != ""
        env_google = System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")
        env_anthropic = System.get_env("ANTHROPIC_API_KEY")

        if not has_google and not has_anthropic and env_google == nil and env_anthropic == nil do
          ["No API keys found in config or environment — API calls will fail" | warnings]
        else
          warnings
        end
      else
        warnings
      end

    if warnings != [] do
      Enum.each(warnings, fn w -> Logger.warning("Config: #{w}") end)
    end
  rescue
    _ -> :ok
  end

  defp setup_file_logging do
    log_file = Path.join(File.cwd!(), "section.log")

    :logger.add_handler(:gitf_file, :logger_std_h, %{
      config: %{file: String.to_charlist(log_file)},
      formatter:
        {GiTF.LogFormatter,
         %{
           template: [
             :time,
             ~c" ",
             :level,
             ~c" ",
             :msg,
             ~c" ",
             :mfa,
             ~c"\n"
           ],
           single_line: true
         }}
    })

    # Configure Elixir Logger to forward metadata keys
    Logger.configure(metadata: [:ghost_id, :op_id, :mission_id, :sector_id, :component])

    :logger.remove_handler(:default)
  end
end
