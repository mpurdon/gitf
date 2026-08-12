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

    # The escript boots this application BEFORE GiTF.CLI.main/1 parses the
    # `-w`/`--workspace` flag, so GITF_PATH isn't set yet and the store would
    # resolve via cwd-walkup (e.g. to the source repo) — silently ignoring -w.
    # Recover the flag from the raw escript args here so store resolution honors
    # it. No-op when GITF_PATH is already set or -w wasn't passed.
    maybe_set_workspace_from_argv()

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

    # Make store resolution observable — otherwise it's impossible to tell from
    # the logs whether `-w`/GITF_PATH took effect or the daemon fell back to the
    # home-dir global store (a real source of "why is this data here?" confusion).
    Logger.info(
      "GiTF store: gitf_root=#{gitf_root} store_dir=#{store_dir} " <>
        "(GITF_PATH=#{System.get_env("GITF_PATH") || "unset"})"
    )

    setup_file_logging(gitf_root)

    # Config.Provider is a supervised child (starts later), but Keys.load/0 runs
    # here — before the tree — and reads [:llm, :keys]. Preload the config into
    # persistent_term now so provider API keys (e.g. google_api_key) actually
    # land in :req_llm; otherwise those reads see an empty config.
    GiTF.Config.Provider.preload(gitf_root)

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
      # Cluster-wide process groups (:pg) — the discovery primitive for
      # distributing the factory across BEAM nodes. Correct single-node.
      GiTF.Distributed.pg_child_spec(),
      {Phoenix.PubSub, name: GiTF.PubSub},
      # Config.Provider must start before Archive (migrations / Archive may read config)
      Supervisor.child_spec(
        {GiTF.Config.Provider, [gitf_root: gitf_root]},
        id: GiTF.Config.Provider
      ),
      # ETS heir must start before Archive so Archive's cache can be made recoverable
      GiTF.Archive.TableHeir,
      {GiTF.Archive, data_dir: store_dir},
      # Per-collection write serializers: same collection → same partition
      # (atomic RMW), different collections → parallel. Starts after Archive so
      # the ETS tables + dirty set exist.
      {PartitionSupervisor, child_spec: GiTF.Archive.Writer, name: GiTF.Archive.Writers},
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
          # Planning-studio sessions (one GenServer per open studio conversation)
          {DynamicSupervisor, name: GiTF.Studio.SessionSupervisor, strategy: :one_for_one},
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
           # A generous restart budget: for a long-running autonomous system a
           # flapping endpoint must not collapse the whole interface subtree via
           # the tight default 3/5s.
           [strategy: :one_for_one, name: GiTF.Interface.Supervisor, max_restarts: 10, max_seconds: 60]
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
           [strategy: :one_for_one, name: GiTF.Plugin.Supervisor, max_restarts: 10, max_seconds: 60]
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

  # Sets GITF_PATH from the escript's `-w`/`--workspace` argument if it wasn't
  # already set by the CLI (which parses it too late for app boot). Reads the
  # raw escript args via :init.get_plain_arguments/0.
  defp maybe_set_workspace_from_argv do
    if System.get_env("GITF_PATH") == nil do
      args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)

      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(fn
        [flag, val] when flag in ["-w", "--workspace"] -> val
        _ -> nil
      end)
      |> case do
        nil -> :ok
        path -> System.put_env("GITF_PATH", Path.expand(path))
      end
    end
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
      {:workflow_dsl_enabled, "GITF_WORKFLOW_DSL_ENABLED", true},
      {:workflow_inference_enabled, "GITF_WORKFLOW_INFERENCE_ENABLED", false},
      {:parallel_impl_attempts, "GITF_PARALLEL_IMPL_ATTEMPTS", 1},
      {:lsp_validation_enabled, "GITF_LSP_VALIDATION_ENABLED", false}
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
  #
  # On bind failure the behavior splits by mode: an interactive CLI invocation
  # boots this same app while a server may legitimately hold the port, so it
  # skips the endpoint and carries on — but a daemon that boots "healthy" with
  # nothing listening is the worst failure mode under a service manager, so
  # server/release boots fail hard instead.
  defp endpoint_child do
    port = Application.get_env(:gitf, GiTF.Web.Endpoint)[:http][:port] || 4000
    try_bind_port(port, 3)
  end

  defp try_bind_port(port, 0) do
    fail_or_skip(port, "Port #{port} still in use after retries")
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
          fail_or_skip(
            port,
            "Port #{port} already in use. A GiTF server may already be running"
          )
        end

      {:error, :eacces} ->
        fail_or_skip(port, "Permission denied for port #{port} — try a port above 1024")

      {:error, reason} ->
        fail_or_skip(port, "Cannot bind to port #{port}: #{inspect(reason)}")
    end
  end

  defp fail_or_skip(port, message) do
    if daemon_mode?() do
      raise "#{message}. Refusing to boot a daemon without its web endpoint — " <>
              "stop the other process or set GITF_PORT to a free port (currently #{port})."
    else
      Logger.info("#{message}. Skipping web endpoint.")
      []
    end
  end

  # A release boot (`bin/gitf start`, systemd, Docker) or an explicit
  # `gitf server`/`gitf daemon` invocation is a daemon; anything else is an
  # interactive CLI run that tolerates a missing endpoint.
  defp daemon_mode? do
    System.get_env("RELEASE_NAME") != nil or
      Enum.any?(:init.get_plain_arguments(), fn arg ->
        List.to_string(arg) in ["server", "daemon"]
      end)
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

    # Aramaki (PM/admission layer) is opt-in — only supervise it when enabled.
    aramaki = if GiTF.Aramaki.enabled?(), do: [{GiTF.Aramaki, []}], else: []

    bg_children = bg ++ optional ++ aramaki

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

  defp setup_file_logging(gitf_root) do
    # Keep logs inside the workspace's .gitf dir (not the cwd, where they
    # polluted the repo) and cap total size: :logger_std_h rotates at
    # max_no_bytes and keeps max_no_files archives (~250 MB ceiling here),
    # so section.log can no longer grow without bound.
    log_dir = Path.join(gitf_root, ".gitf/logs")
    File.mkdir_p(log_dir)
    log_file = Path.join(log_dir, "section.log")

    :logger.add_handler(:gitf_file, :logger_std_h, %{
      config: %{
        file: String.to_charlist(log_file),
        max_no_bytes: 50_000_000,
        max_no_files: 5
      },
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

    if stdout_logging?() do
      configure_stdout_handler()
    else
      # Interactive CLI: keep stdout clean for command output; logs go to the
      # file handler above.
      :logger.remove_handler(:default)
    end
  end

  # Whether the default stdout handler should stay attached. Under a service
  # manager an empty stdout means empty `journalctl`/`docker logs` — the
  # operator's primary debugging surface — so releases default to keeping it.
  # GITF_LOG_STDOUT overrides in either direction.
  defp stdout_logging? do
    case System.get_env("GITF_LOG_STDOUT") do
      nil -> System.get_env("RELEASE_NAME") != nil
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  defp configure_stdout_handler do
    formatter =
      case System.get_env("GITF_LOG_FORMAT") do
        json when json in ["json", "JSON"] ->
          {GiTF.LogFormatter.JSON, %{}}

        _ ->
          {GiTF.LogFormatter,
           %{
             template: [:time, ~c" ", :level, ~c" ", :msg, ~c" ", :mfa, ~c"\n"],
             single_line: true
           }}
      end

    :logger.update_handler_config(:default, :formatter, formatter)
  end
end
