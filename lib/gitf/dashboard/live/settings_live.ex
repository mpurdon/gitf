defmodule GiTF.Dashboard.SettingsLive do
  @moduledoc "Configuration management dashboard."

  use Phoenix.LiveView
  use GiTF.Dashboard.Toastable

  @impl true
  def mount(_params, _session, socket) do
    config = load_config()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:current_path, "/dashboard/settings")
     |> assign(:config, config)
     |> assign(:dirty, false)
     |> init_toasts()}
  end

  @impl true
  def handle_event("update", %{"config" => params}, socket) do
    config = merge_params(socket.assigns.config, params)
    {:noreply, assign(socket, config: config, dirty: true)}
  end

  def handle_event("save", _params, socket) do
    config = socket.assigns.config

    case save_config(config) do
      :ok ->
        GiTF.Config.Provider.reload()

        {:noreply,
         socket
         |> assign(:dirty, false)
         |> put_flash(:info, "Settings saved and reloaded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("reload", _params, socket) do
    config = load_config()

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:dirty, false)
     |> put_flash(:info, "Config reloaded from disk.")}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_config do
    case config_path() do
      {:ok, path} ->
        case GiTF.Config.read_config(path) do
          {:ok, cfg} -> cfg
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_config(config) do
    case config_path() do
      {:ok, path} -> GiTF.Config.write_config(path, config)
      _ -> {:error, :no_config_path}
    end
  end

  defp config_path do
    case GiTF.gitf_dir() do
      {:ok, root} -> {:ok, Path.join([root, ".gitf", "config.toml"])}
      error -> error
    end
  end

  defp merge_params(config, params) do
    Enum.reduce(params, config, fn {section, values}, acc ->
      current = Map.get(acc, section, %{})

      updated =
        Enum.reduce(values, current, fn {key, value}, sec ->
          # LLM keys are stored nested under "keys" in the TOML
          if section == "llm" and key in ["anthropic", "google"] do
            keys = Map.get(sec, "keys", %{})
            Map.put(sec, "keys", Map.put(keys, key, value))
          else
            Map.put(sec, key, coerce(section, key, value))
          end
        end)

      Map.put(acc, section, updated)
    end)
  end

  # Coerce form string values to appropriate types
  defp coerce("costs", "budget_usd", v), do: parse_float(v)
  defp coerce("costs", "warn_threshold_usd", v), do: parse_float(v)
  defp coerce("ghost", "spawn_timeout_ms", v), do: parse_int(v)
  defp coerce("major", "max_ghosts", v), do: parse_int(v)
  defp coerce("major", "dark_factory", "true"), do: true
  defp coerce("major", "dark_factory", _), do: false
  defp coerce("tachikoma", _key, v), do: parse_int(v)
  defp coerce(_section, _key, v), do: v

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> v
    end
  end

  defp parse_float(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> v
    end
  end

  defp parse_int(v), do: v

  defp config_val(config, section, key, default \\ "") do
    config |> Map.get(section, %{}) |> Map.get(key, default) |> to_string()
  end

  defp checked?(config, section, key) do
    config |> Map.get(section, %{}) |> Map.get(key, false) |> to_string() == "true"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={GiTF.Dashboard.AppLayout} id="layout" current_path={@current_path} flash={@flash} toasts={@toasts}>
      <div style="max-width:640px">
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:1rem">
          <h1 class="page-title" style="margin:0">Settings</h1>
          <div style="display:flex; gap:0.5rem">
            <button phx-click="reload" class="btn btn-grey" style="font-size:0.8rem">Reload</button>
            <button phx-click="save" class="btn btn-green" style="font-size:0.8rem" disabled={not @dirty}>
              {if @dirty, do: "Save Changes", else: "Saved"}
            </button>
          </div>
        </div>

        <form phx-change="update">
          <%!-- GitHub --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">GitHub</h3>
            <div class="form-group">
              <label class="form-label">Personal Access Token</label>
              <input
                id="gh-token"
                type="password"
                name="config[github][token]"
                class="form-input"
                value={config_val(@config, "github", "token")}
                placeholder="ghp_..."
                phx-debounce="300"
                autocomplete="off"
              />
              <p style="color:#6b7280; font-size:0.75rem; margin:0.25rem 0 0">
                Required for GitHub issue browsing and PR creation. Create at github.com/settings/tokens.
              </p>
            </div>
          </div>

          <%!-- LLM Keys --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">LLM API Keys</h3>
            <div class="form-group">
              <label class="form-label">Anthropic</label>
              <input
                id="llm-anthropic"
                type="password"
                name="config[llm][anthropic]"
                class="form-input"
                value={get_in(@config, ["llm", "keys", "anthropic"]) || ""}
                placeholder="sk-ant-..."
                phx-debounce="300"
                autocomplete="off"
              />
            </div>
            <div class="form-group">
              <label class="form-label">Google</label>
              <input
                id="llm-google"
                type="password"
                name="config[llm][google]"
                class="form-input"
                value={get_in(@config, ["llm", "keys", "google"]) || ""}
                placeholder="AIza..."
                phx-debounce="300"
                autocomplete="off"
              />
            </div>
          </div>

          <%!-- Factory --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">Factory</h3>
            <div style="display:flex; gap:1rem; flex-wrap:wrap">
              <div class="form-group" style="flex:1; min-width:120px">
                <label class="form-label">Max Ghosts</label>
                <input
                  id="major-max-ghosts"
                  type="number"
                  name="config[major][max_ghosts]"
                  class="form-input"
                  value={config_val(@config, "major", "max_ghosts", "5")}
                  min="1"
                  max="20"
                  phx-debounce="300"
                />
              </div>
              <div class="form-group" style="flex:1; min-width:120px">
                <label class="form-label">Dark Factory</label>
                <select name="config[major][dark_factory]" class="form-select">
                  <option value="true" selected={checked?(@config, "major", "dark_factory")}>Enabled</option>
                  <option value="false" selected={not checked?(@config, "major", "dark_factory")}>Disabled</option>
                </select>
              </div>
            </div>
          </div>

          <%!-- Budget --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">Budget</h3>
            <div style="display:flex; gap:1rem; flex-wrap:wrap">
              <div class="form-group" style="flex:1; min-width:120px">
                <label class="form-label">Budget (USD)</label>
                <input
                  id="costs-budget"
                  type="number"
                  name="config[costs][budget_usd]"
                  class="form-input"
                  value={config_val(@config, "costs", "budget_usd", "10.0")}
                  step="0.5"
                  min="0"
                  phx-debounce="300"
                />
              </div>
              <div class="form-group" style="flex:1; min-width:120px">
                <label class="form-label">Warning Threshold (USD)</label>
                <input
                  id="costs-warn"
                  type="number"
                  name="config[costs][warn_threshold_usd]"
                  class="form-input"
                  value={config_val(@config, "costs", "warn_threshold_usd", "5.0")}
                  step="0.5"
                  min="0"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>

          <%!-- Observability --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">Observability</h3>
            <div class="form-group">
              <label class="form-label">Webhook URL</label>
              <input
                id="obs-webhook"
                type="url"
                name="config[observability][webhook_url]"
                class="form-input"
                value={config_val(@config, "observability", "webhook_url")}
                placeholder="https://hooks.slack.com/..."
                phx-debounce="300"
              />
            </div>
          </div>

          <%!-- Tachikoma --%>
          <div class="panel" style="margin-bottom:1rem">
            <h3 style="color:#c9d1d9; margin:0 0 0.75rem; font-size:0.95rem">Tachikoma</h3>
            <div style="display:flex; gap:1rem; flex-wrap:wrap">
              <div class="form-group" style="flex:1; min-width:140px">
                <label class="form-label">Patrol Interval (ms)</label>
                <input
                  id="tach-patrol"
                  type="number"
                  name="config[tachikoma][patrol_interval_ms]"
                  class="form-input"
                  value={config_val(@config, "tachikoma", "patrol_interval_ms", "30000")}
                  min="5000"
                  step="1000"
                  phx-debounce="300"
                />
              </div>
              <div class="form-group" style="flex:1; min-width:140px">
                <label class="form-label">Archive Prune Age (hours)</label>
                <input
                  id="tach-prune"
                  type="number"
                  name="config[tachikoma][archive_prune_age_hours]"
                  class="form-input"
                  value={config_val(@config, "tachikoma", "archive_prune_age_hours", "48")}
                  min="1"
                  phx-debounce="300"
                />
              </div>
            </div>
          </div>
        </form>

        <div style="text-align:center; color:#484f58; font-size:0.75rem; margin-top:1rem">
          Config file: <code>.gitf/config.toml</code>
        </div>
      </div>
    </.live_component>
    """
  end
end
