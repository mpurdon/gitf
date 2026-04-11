defmodule GiTF.Dashboard.ProvidersLive do
  @moduledoc "LLM Fleet Control — configure provider priority, fallback strategy, and API keys."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable
  import GiTF.Dashboard.Helpers

  alias GiTF.Runtime.{ProviderManager, ProviderCircuit}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GiTF.PubSub, "provider:circuit")
    end

    {configured, unconfigured} = ProviderManager.list_providers()

    # Ollama status
    ollama_running = GiTF.Runtime.Ollama.running?()

    ollama_models =
      if ollama_running do
        case GiTF.Runtime.Ollama.list_models() do
          {:ok, models} -> models
          _ -> []
        end
      else
        []
      end

    {:ok,
     socket
     |> assign(:page_title, "Providers")
     |> assign(:current_path, "/providers")
     |> assign(:configured, configured)
     |> assign(:unconfigured, unconfigured)
     |> assign(:priority, ProviderManager.provider_priority())
     |> assign(:fallback_strategy, ProviderManager.fallback_strategy())
     |> assign(:expanded, nil)
     |> assign(:editing, %{})
     |> assign(:test_results, %{})
     |> assign(:circuit_states, load_circuit_states())
     |> assign(:stats, load_stats())
     |> assign(:dirty, false)
     |> assign(:saving, false)
     |> assign(:ollama_running, ollama_running)
     |> assign(:ollama_models, ollama_models)
     |> assign(:starting_ollama, false)
     |> init_toasts()}
  end

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event("move_up", %{"provider" => name}, socket) do
    priority = socket.assigns.priority
    idx = Enum.find_index(priority, &(&1 == name))

    if idx && idx > 0 do
      new_priority = swap(priority, idx, idx - 1)

      {:noreply,
       socket |> assign(:priority, new_priority) |> assign(:dirty, true) |> reload_providers()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_down", %{"provider" => name}, socket) do
    priority = socket.assigns.priority
    idx = Enum.find_index(priority, &(&1 == name))

    if idx && idx < length(priority) - 1 do
      new_priority = swap(priority, idx, idx + 1)

      {:noreply,
       socket |> assign(:priority, new_priority) |> assign(:dirty, true) |> reload_providers()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_enabled", %{"provider" => name}, socket) do
    editing = socket.assigns.editing
    current = get_in(editing, [name, "enabled"])
    provider = Enum.find(socket.assigns.configured, &(&1.name == name))
    enabled = if is_nil(current), do: !provider.enabled, else: !current
    editing = put_in(editing, [Access.key(name, %{}), "enabled"], enabled)
    {:noreply, socket |> assign(:editing, editing) |> assign(:dirty, true)}
  end

  def handle_event("expand", %{"provider" => name}, socket) do
    expanded = if socket.assigns.expanded == name, do: nil, else: name
    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("set_fallback", %{"strategy" => strategy}, socket) do
    {:noreply, socket |> assign(:fallback_strategy, strategy) |> assign(:dirty, true)}
  end

  def handle_event(
        "update_provider_config",
        %{"provider" => name, "config" => config},
        socket
      ) do
    current_edits = Map.get(socket.assigns.editing, name, %{})
    new_edits = Map.merge(current_edits, config)
    editing = put_in(socket.assigns.editing, [Access.key(name, %{})], new_edits)
    {:noreply, socket |> assign(:editing, editing) |> assign(:dirty, true)}
  end

  def handle_event("test_connection", %{"provider" => name}, socket) do
    test_results = Map.put(socket.assigns.test_results, name, :testing)
    edits = Map.get(socket.assigns.editing, name, %{})
    provider = Enum.find(socket.assigns.configured, &(&1.name == name))

    opts = %{
      aws_profile: Map.get(edits, "aws_profile", provider && provider.aws_profile),
      aws_region: Map.get(edits, "aws_region", provider && provider.aws_region),
      fast: Map.get(edits, "fast", provider && to_string(provider.models.fast)),
      general: Map.get(edits, "general", provider && to_string(provider.models.general))
    }

    Task.async(fn -> {:test_result, name, ProviderManager.test_connection(name, opts)} end)
    {:noreply, assign(socket, :test_results, test_results)}
  end

  def handle_event("dismiss_test", %{"provider" => name}, socket) do
    test_results = Map.delete(socket.assigns.test_results, name)
    {:noreply, assign(socket, :test_results, test_results)}
  end

  def handle_event("add_provider", %{"provider" => name}, socket) do
    priority = socket.assigns.priority ++ [name]

    {:noreply,
     socket |> assign(:priority, priority) |> assign(:dirty, true) |> reload_providers()}
  end

  def handle_event("start_ollama", _, socket) do
    # Spawn a task to start Ollama and notify us when done
    Task.async(fn ->
      case GiTF.Runtime.Ollama.start_server() do
        {:ok, _} -> {:ollama_started, :ok}
        {:error, reason} -> {:ollama_started, {:error, reason}}
      end
    end)

    {:noreply, assign(socket, :starting_ollama, true)}
  end

  def handle_event("save", _params, socket) do
    provider_configs =
      Enum.reduce(socket.assigns.priority, %{}, fn name, acc ->
        edits = Map.get(socket.assigns.editing, name, %{})
        provider = Enum.find(socket.assigns.configured, &(&1.name == name))

        config = %{
          "enabled" => Map.get(edits, "enabled", (provider && provider.enabled) || true),
          "thinking" =>
            Map.get(edits, "thinking", (provider && to_string(provider.models.thinking)) || ""),
          "general" =>
            Map.get(edits, "general", (provider && to_string(provider.models.general)) || ""),
          "fast" => Map.get(edits, "fast", (provider && to_string(provider.models.fast)) || "")
        }

        config =
          case Map.get(edits, "api_key") do
            key when is_binary(key) and key != "" -> Map.put(config, "api_key", key)
            _ -> config
          end

        config =
          case Map.get(edits, "aws_profile") do
            profile when is_binary(profile) and profile != "" ->
              Map.put(config, "aws_profile", profile)

            _ ->
              config
          end

        config =
          case Map.get(edits, "aws_region") do
            region when is_binary(region) and region != "" ->
              Map.put(config, "aws_region", region)

            _ ->
              config
          end

        Map.put(acc, name, config)
      end)

    case ProviderManager.save!(
           socket.assigns.priority,
           socket.assigns.fallback_strategy,
           provider_configs
         ) do
      :ok ->
        {configured, unconfigured} = ProviderManager.list_providers()

        {:noreply,
         socket
         |> assign(:configured, configured)
         |> assign(:unconfigured, unconfigured)
         |> assign(:priority, ProviderManager.provider_priority())
         |> assign(:editing, %{})
         |> assign(:dirty, false)
         |> put_flash(:info, "Configuration saved and reloaded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{reason}")}
    end
  end

  @impl true
  def handle_info({ref, {:test_result, name, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    test_results = Map.put(socket.assigns.test_results, name, result)
    {:noreply, assign(socket, :test_results, test_results)}
  end

  def handle_info({ref, {:ollama_started, result}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        :ok ->
          socket
          |> assign(:ollama_running, true)
          |> assign(:starting_ollama, false)
          |> put_flash(:info, "Ollama server started successfully.")

        {:error, reason} ->
          socket
          |> assign(:starting_ollama, false)
          |> put_flash(:error, "Failed to start Ollama: #{inspect(reason)}")
      end

    # Also try to fetch models if it started
    socket =
      if socket.assigns.ollama_running do
        case GiTF.Runtime.Ollama.list_models() do
          {:ok, models} -> assign(socket, :ollama_models, models)
          _ -> socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:circuit_reset, _provider, _latency}, socket) do
    {:noreply, assign(socket, :circuit_states, load_circuit_states())}
  end

  def handle_info({:circuit_opened, _provider, _failure_mode}, socket) do
    {:noreply, assign(socket, :circuit_states, load_circuit_states())}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  # -- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>

    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem">
      <h1 class="page-title">LLM Fleet Control</h1>
      <button
        phx-click="save"
        class={"btn #{if @dirty, do: "btn-green", else: "btn-grey"}"}
        disabled={not @dirty}
      >{if @saving, do: "Saving...", else: "Save Changes"}</button>
    </div>

    <%!-- Fallback Strategy --%>
    <div class="panel" style="margin-bottom:1rem">
      <div class="panel-title">Fallback Strategy</div>
      <div style="display:flex; gap:0.75rem; margin-top:0.5rem; flex-wrap:wrap">
        <div
          class={"strategy-option #{if @fallback_strategy == "priority_chain", do: "selected"}"}
          phx-click="set_fallback" phx-value-strategy="priority_chain"
        >
          <div style="font-weight:600; color:#f0f6fc; margin-bottom:0.2rem">Priority Chain</div>
          <div style="font-size:0.8rem; color:#8b949e">Try next provider at same tier, then downgrade</div>
        </div>
        <div
          class={"strategy-option #{if @fallback_strategy == "tier_downgrade_first", do: "selected"}"}
          phx-click="set_fallback" phx-value-strategy="tier_downgrade_first"
        >
          <div style="font-weight:600; color:#f0f6fc; margin-bottom:0.2rem">Tier Downgrade First</div>
          <div style="font-size:0.8rem; color:#8b949e">Try cheaper model on same provider, then switch</div>
        </div>
      </div>
    </div>

    <%!-- Unconfigured providers --%>
    <div :if={unconfigured_available(@unconfigured, @priority) != []} class="panel" style="margin-bottom:1rem">
      <div class="panel-title">Available Providers</div>
      <div style="display:flex; gap:0.5rem; flex-wrap:wrap; margin-top:0.5rem">
        <div :for={provider <- unconfigured_available(@unconfigured, @priority)} style="display:flex; align-items:center; gap:0.4rem">
          <span class="provider-glyph" style={"width:28px; height:28px; font-size:0.85rem; color:#{provider.color}; border-color:#{provider.color}55; background:#{provider.color}11"}>
            {provider.glyph}
          </span>
          <span style="font-size:0.85rem; color:#8b949e">{String.capitalize(provider.name)}</span>
          <button class="btn btn-grey" style="font-size:0.7rem; padding:0.15rem 0.4rem" phx-click="add_provider" phx-value-provider={provider.name}>Add</button>
        </div>
      </div>
    </div>

    <%!-- Provider Priority --%>
    <div class="panel" style="margin-bottom:1rem">
      <div class="panel-title">Provider Priority</div>

      <div :for={{name, idx} <- Enum.with_index(@priority)} id={"provider-card-#{name}"} style="margin-top:0.5rem">
        <% provider = Enum.find(@configured, &(&1.name == name)) || ProviderManager.provider_info(name)
           edits = Map.get(@editing, name, %{})
           enabled = Map.get(edits, "enabled", provider.enabled)
           status = provider.status
           expanded = @expanded == name
           test_result = Map.get(@test_results, name)
           circuit = Map.get(@circuit_states, name, %{state: :closed}) %>

        <div class={"provider-card #{if not enabled, do: "provider-card-disabled"}"}>
          <div class="provider-glyph" style={"color:#{provider.color}; border-color:#{provider.color}55; background:#{provider.color}11; text-shadow:0 0 8px #{provider.color}66"}>
            {provider.glyph}
          </div>

          <div style="flex:1; min-width:0">
            <div style="display:flex; align-items:center; gap:0.5rem; margin-bottom:0.25rem; flex-wrap:wrap">
              <span style="font-weight:600; color:#f0f6fc; font-size:0.95rem">{String.capitalize(name)}</span>
              <span class={"provider-status-#{status}"} style="font-size:0.75rem">
                {case status do
                  :connected -> "● connected"
                  :configured -> "○ configured"
                  :unconfigured -> "○ unconfigured"
                end}
              </span>
              <span :if={circuit.state == :open} style="font-size:0.7rem; background:#f8514922; color:#f85149; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid #f8514944">
                ⊘ circuit open
              </span>
              <span :if={circuit.state == :half_open} style="font-size:0.7rem; background:#d2992222; color:#d29922; padding:0.1rem 0.4rem; border-radius:4px; border:1px solid #d2992244">
                ◐ half-open
              </span>
            </div>
            <div style="font-size:0.75rem; color:#8b949e; font-family:monospace; display:flex; gap:1rem">
              <span>🧠 {shorten_model_name(provider.models.thinking)}</span>
              <span>◈ {shorten_model_name(provider.models.general)}</span>
              <span>⚡ {shorten_model_name(provider.models.fast)}</span>
            </div>
            <div :if={circuit.state == :open} style="font-size:0.72rem; margin-top:0.3rem; color:#f85149; display:flex; gap:0.75rem; flex-wrap:wrap; align-items:center">
              <span style="color:#8b949e">
                {circuit_failure_label(circuit.failure_mode)}
              </span>
              <span style="color:#484f58">|</span>
              <span style="color:#8b949e">
                next probe {circuit_next_probe_label(circuit.next_probe_in)}
              </span>
            </div>
          </div>

          <div style="display:flex; align-items:center; gap:0.4rem">
            <button class="reorder-btn" phx-click="move_up" phx-value-provider={name} disabled={idx == 0}>▲</button>
            <button class="reorder-btn" phx-click="move_down" phx-value-provider={name} disabled={idx == length(@priority) - 1}>▼</button>
          </div>

          <div class="toggle" phx-click="toggle_enabled" phx-value-provider={name}>
            <div class={"toggle-track #{if enabled, do: "on"}"}></div>
            <div class={"toggle-knob #{if enabled, do: "on"}"}></div>
          </div>

          <button class="reorder-btn" phx-click="expand" phx-value-provider={name} style="font-size:0.75rem">
            {if expanded, do: "▾", else: "▸"}
          </button>
        </div>

        <%!-- Expanded config --%>
        <div :if={expanded} id={"provider-config-#{name}"} style="background:#0d1117; border:1px solid #21262d; border-top:none; border-radius:0 0 8px 8px; padding:1rem; margin-top:-0.5rem; margin-bottom:0.5rem">
          <form id={"provider-form-#{name}"} phx-change="update_provider_config" phx-submit="update_provider_config">
            <input type="hidden" name="provider" value={name} />
            <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:0.75rem; margin-bottom:0.75rem">
              <.model_input
                label="🧠 Thinking Model"
                provider_name={name}
                field="thinking"
                current_val={Map.get(edits, "thinking", to_string(provider.models.thinking)) |> rewrite_legacy_prefix(name)}
                ollama_running={@ollama_running}
                ollama_models={@ollama_models}
              />
              <.model_input
                label="◈ General Model"
                provider_name={name}
                field="general"
                current_val={Map.get(edits, "general", to_string(provider.models.general)) |> rewrite_legacy_prefix(name)}
                ollama_running={@ollama_running}
                ollama_models={@ollama_models}
              />
              <.model_input
                label="⚡ Fast Model"
                provider_name={name}
                field="fast"
                current_val={Map.get(edits, "fast", to_string(provider.models.fast)) |> rewrite_legacy_prefix(name)}
                ollama_running={@ollama_running}
                ollama_models={@ollama_models}
              />
            </div>

            <%!-- Auth section --%>
            <div style="display:flex; gap:1rem; align-items:flex-end; margin-bottom:0.75rem">
              <div :if={provider.auth == :api_key} style="flex:1">
                <label style="font-size:0.75rem; color:#8b949e; display:block; margin-bottom:0.2rem">API Key</label>
                <input
                  class="form-input"
                  style="font-size:0.8rem; font-family:monospace"
                  type="password"
                  placeholder={if provider.api_key_set, do: "••••••••••••••••", else: "Enter API key..."}
                  value={Map.get(edits, "api_key", "")}
                  name="config[api_key]"
                  phx-debounce="500"
                />
              </div>
              <div :if={provider.auth == :aws_profile} style="flex:1">
                <label style="font-size:0.75rem; color:#8b949e; display:block; margin-bottom:0.2rem">AWS Profile Name</label>
                <input
                  class="form-input"
                  style="font-size:0.8rem; font-family:monospace"
                  placeholder="e.g. nieto"
                  value={Map.get(edits, "aws_profile", provider.aws_profile || "")}
                  name="config[aws_profile]"
                  phx-debounce="500"
                />
              </div>
              <div :if={provider.auth == :aws_profile} style="width:150px">
                <label style="font-size:0.75rem; color:#8b949e; display:block; margin-bottom:0.2rem">AWS Region</label>
                <select
                  class="form-select"
                  style="font-size:0.8rem; font-family:monospace"
                  name="config[aws_region]"
                >
                  <option :for={region <- aws_regions()} value={region} selected={region == (Map.get(edits, "aws_region", provider.aws_region) || "us-east-1")}>
                    {region}
                  </option>
                </select>
              </div>

              <div>
                <button
                  type="button"
                  class={"btn #{case test_result do; {:ok, _} -> "btn-green"; :testing -> "btn-grey"; _ -> "btn-blue" end}"}
                  phx-click="test_connection"
                  phx-value-provider={name}
                  disabled={test_result == :testing}
                  style="font-size:0.8rem; white-space:nowrap"
                >
                  {case test_result do
                    :testing -> "Testing..."
                    {:ok, ms} -> "✓ #{ms}ms"
                    _ -> "Test Connection"
                  end}
                </button>
              </div>
            </div>

            <div :if={match?({:error, _}, test_result)} style="background:#f8514911; border:1px solid #f8514933; border-radius:6px; padding:0.5rem 0.75rem; margin-top:0.5rem; display:flex; justify-content:space-between; align-items:flex-start; gap:0.5rem">
              <div style="font-size:0.8rem; color:#f85149; flex:1; word-break:break-word; white-space:pre-wrap">
                {format_test_error(test_result)}
              </div>
              <button
                type="button"
                class="btn btn-grey"
                style="font-size:0.7rem; padding:0.15rem 0.4rem; flex-shrink:0"
                phx-click="dismiss_test"
                phx-value-provider={name}
              >✕</button>
            </div>
          </form>
        </div>
      </div>
    </div>

    <%!-- Ollama Local Server --%>
    <div class="panel" style="margin-bottom:1rem" :if={Enum.any?(@priority, &(&1 == "ollama")) or @ollama_running}>
      <div class="panel-title">Ollama Local Server</div>
      <div style="display:flex; justify-content:space-between; align-items:center; margin-top:0.5rem">
        <div style="display:flex; align-items:center; gap:0.5rem">
           <span class={"badge #{if @ollama_running, do: "badge-green", else: "badge-grey"}"}>
             {if @ollama_running, do: "Running", else: "Stopped"}
           </span>
           <span :if={@ollama_running} style="font-size:0.8rem; color:#8b949e">
             {@ollama_models |> length()} models available
           </span>
        </div>
        <div>
          <button :if={not @ollama_running} class="btn btn-blue" phx-click="start_ollama" disabled={@starting_ollama}>
            {if @starting_ollama, do: "Starting...", else: "Start Server"}
          </button>
        </div>
      </div>
      <div :if={@ollama_running and @ollama_models != []} style="margin-top:1rem; display:flex; flex-wrap:wrap; gap:0.5rem">
         <span :for={model <- @ollama_models} class="badge badge-grey" style="font-family:monospace; font-size:0.75rem">{model}</span>
      </div>
      <div :if={@ollama_running and @ollama_models == []} style="margin-top:1rem; font-size:0.8rem; color:#8b949e">
        No models found. Run <code style="color:#d2a8ff; background:#1c2128; padding:0.1rem 0.3rem; border-radius:3px">ollama pull &lt;model&gt;</code> in your terminal.
      </div>
    </div>

    <%!-- Fleet Status --%>
    <div class="panel">
      <div class="panel-title">Fleet Status</div>
      <table style="width:100%; margin-top:0.5rem">
        <thead>
          <tr><th>Provider</th><th>Circuit</th><th>Calls</th><th>Cost</th></tr>
        </thead>
        <tbody>
          <tr :for={{name, stats} <- @stats}>
            <% cs = Map.get(@circuit_states, name, %{state: :closed}) %>
            <td style="font-weight:600">{String.capitalize(name)}</td>
            <td>{circuit_state_badge(cs.state)}</td>
            <td>{stats.total_calls}</td>
            <td>{format_cost(stats.total_cost)}</td>
          </tr>
          <tr :if={@stats == []}>
            <td colspan="3" style="color:#8b949e; text-align:center">No API calls recorded yet.</td>
          </tr>
        </tbody>
      </table>
    </div>

    </.live_component>
    """
  end

  # -- Private ---------------------------------------------------------------

  defp reload_providers(socket) do
    priority = socket.assigns.priority
    configured = Enum.map(priority, &ProviderManager.provider_info/1)
    unconfigured_names = Map.keys(ProviderManager.known_providers()) -- priority
    unconfigured = unconfigured_names |> Enum.sort() |> Enum.map(&ProviderManager.provider_info/1)
    assign(socket, configured: configured, unconfigured: unconfigured)
  end

  defp load_stats do
    ProviderManager.provider_priority()
    |> Enum.map(fn name -> {name, ProviderManager.provider_stats(name)} end)
  rescue
    _ -> []
  end

  defp unconfigured_available(unconfigured, priority) do
    Enum.reject(unconfigured, &(&1.name in priority))
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end

  # Diagnostic map from test_connection
  defp format_test_error({:error, %{message: msg, context: ctx}}) do
    details =
      ctx
      |> Enum.reject(fn {k, v} -> k == :stacktrace or is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join(" · ")

    if details == "", do: msg, else: "#{msg}\n#{details}"
  end

  defp format_test_error({:error, reason}) when is_binary(reason), do: reason
  defp format_test_error({:error, reason}) when is_atom(reason), do: "#{reason}"
  defp format_test_error({:error, reason}), do: inspect(reason, limit: 300)
  defp format_test_error(_), do: "Unknown error"

  defp aws_regions do
    [
      "us-east-1",
      "us-east-2",
      "us-west-2",
      "eu-west-1",
      "eu-west-3",
      "eu-central-1",
      "ap-southeast-1",
      "ap-southeast-2",
      "ap-northeast-1",
      "ca-central-1",
      "sa-east-1"
    ]
  end

  defp load_circuit_states do
    ProviderManager.provider_priority()
    |> Enum.map(fn name ->
      state = ProviderCircuit.provider_state(name)

      {name,
       %{
         state: state,
         failure_mode: if(state == :open, do: ProviderCircuit.failure_mode(name)),
         next_probe_in: if(state == :open, do: ProviderCircuit.seconds_until_probe(name))
       }}
    end)
    |> Map.new()
  rescue
    e ->
      require Logger
      Logger.warning("load_circuit_states failed: #{Exception.message(e)}")
      %{}
  end

  defp circuit_failure_label(nil), do: ""
  defp circuit_failure_label(:quota_exhausted), do: "quota/spending cap exhausted"
  defp circuit_failure_label(:billing_error), do: "billing/payment issue"
  defp circuit_failure_label(:rate_limited), do: "rate limited"
  defp circuit_failure_label(:auth_error), do: "authentication error"
  defp circuit_failure_label(:server_error), do: "server error"
  defp circuit_failure_label(:connection_error), do: "connection error"
  defp circuit_failure_label(:model_not_found), do: "model not found"
  defp circuit_failure_label(:unknown), do: "unknown error"
  defp circuit_failure_label(mode), do: to_string(mode)

  defp circuit_next_probe_label(nil), do: ""
  defp circuit_next_probe_label(0), do: "due now"
  defp circuit_next_probe_label(s) when s < 60, do: "in #{s}s"
  defp circuit_next_probe_label(s), do: "in #{div(s, 60)}m"

  defp circuit_state_badge(:closed), do: "✓"
  defp circuit_state_badge(:open), do: "⊘"
  defp circuit_state_badge(:half_open), do: "◐"
  defp circuit_state_badge(_), do: "✓"

  defp shorten_model_name(model) do
    model
    |> to_string()
    |> String.replace(~r/^[^:]+:/, "")
    |> String.replace(~r/-\d{8}.*$/, "")
    |> String.replace(~r/-v\d+:\d+$/, "")
    |> String.slice(0, 25)
  end

  defp rewrite_legacy_prefix(model, "ollama") do
    if String.starts_with?(model, "openai:") do
      String.replace(model, ~r/^openai:/, "ollama:")
    else
      model
    end
  end

  defp rewrite_legacy_prefix(model, _), do: model

  defp model_input(assigns) do
    ~H"""
    <div>
      <label style="font-size:0.75rem; color:#8b949e; display:block; margin-bottom:0.2rem">{@label}</label>
      <%= if @provider_name == "ollama" and @ollama_running and @ollama_models != [] do %>
        <select
          class="form-select"
          style="font-size:0.8rem; font-family:monospace; width:100%"
          name={"config[#{@field}]"}
        >
          <option :for={model <- @ollama_models} value={"ollama:#{model}"} selected={"ollama:#{model}" == @current_val}>
            {model}
          </option>
          <option :if={@current_val not in Enum.map(@ollama_models, &("ollama:" <> &1))} value={@current_val} selected>
            {String.replace(@current_val, "ollama:", "")} (not downloaded)
          </option>
        </select>
      <% else %>
        <input
          class="form-input"
          style="font-size:0.8rem; font-family:monospace; width:100%"
          value={@current_val}
          name={"config[#{@field}]"}
          phx-debounce="blur"
        />
      <% end %>
    </div>
    """
  end
end
