defmodule GiTF.Config do
  @moduledoc """
  Reads, writes, and provides defaults for GiTF configuration files.

  Two config files are supported:

    * **Global** (`~/.config/gitf/config.toml`) — API keys, budgets, thresholds,
      and other user-wide settings.
    * **Project** (`<project>/.gitf/config.toml`) — version, session state, and
      optional per-project overrides that merge on top of global config.
  """

  @global_default_config %{
    "major" => %{
      "max_ghosts" => 5,
      "dark_factory" => false
    },
    "ghost" => %{"spawn_timeout_ms" => 30_000},
    "tachikoma" => %{
      "patrol_interval_ms" => 30_000,
      "archive_prune_age_hours" => 48,
      "cost_retention_hours" => 168,
      "artifact_compact_days" => 7,
      "pattern_retention_max" => 200
    },
    "costs" => %{
      "warn_threshold_usd" => 5.0,
      "budget_usd" => 10.0,
      # Factory-wide safety ceiling: total spend across ALL missions in a
      # rolling 24h window. Fail-closed — new ghosts/missions are refused once
      # hit. Conservative by default; raise consciously for higher throughput.
      "daily_budget_usd" => 100.0
    },
    "llm" => %{"keys" => %{"google" => "", "anthropic" => ""}},
    "github" => %{"token" => ""},
    # Ministry identity (docs/plans/ministry.md M1). Empty = today's
    # behaviour: commits use whatever git identity the host has, and PR
    # bodies get the Ghost in the Shell quote. A client box sets all three.
    "git" => %{"author_name" => "", "author_email" => "", "attribution" => ""},
    "server" => %{"url" => ""},
    "observability" => %{"webhook_url" => ""}
  }

  @doc "Returns the default global configuration map (API keys, budgets, thresholds)."
  @spec global_default_config() :: map()
  def global_default_config, do: @global_default_config

  @doc """
  Returns the default project configuration map (version, session).

  Built at call-time so `GiTF.version/0` reads the current `mix.exs`
  string — otherwise a module-attribute snapshot would freeze whatever
  version was compiled into the beam.
  """
  @spec project_default_config() :: map()
  def project_default_config do
    %{
      "gitf" => %{"version" => GiTF.version()},
      "session" => %{"current_sector" => ""}
    }
  end

  @doc """
  Returns the full default configuration map (global + project merged).

  ## Examples

      iex> config = GiTF.Config.default_config()
      iex> config["major"]["max_ghosts"]
      5
  """
  @spec default_config() :: map()
  def default_config, do: Map.merge(@global_default_config, project_default_config())

  @doc """
  Writes a configuration map to the given file path as TOML.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write_config(String.t(), map() | nil) :: :ok | {:error, term()}
  def write_config(path, config \\ nil) do
    content = encode_toml(config || default_config())

    with :ok <- File.write(path, content) do
      # config.toml can hold provider API keys — owner-only, like the MCP socket.
      File.chmod(path, 0o600)
    end
  end

  @doc """
  Reads and parses a TOML configuration file.

  Returns `{:ok, map}` on success or `{:error, reason}` on failure.
  """
  @spec read_config(String.t()) :: {:ok, map()} | {:error, term()}
  def read_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- Toml.decode(content) do
      {:ok, parsed}
    end
  end

  @doc """
  Updates the major configuration and persists it to the global config file.
  """
  @spec update_major_config(map()) :: :ok | {:error, term()}
  def update_major_config(new_major_config) do
    global_path = GiTF.global_config_path()

    existing =
      case read_config(global_path) do
        {:ok, cfg} -> cfg
        _ -> %{}
      end

    current_major = Map.get(existing, "major", %{})
    updated_major = Map.merge(current_major, new_major_config)
    updated = Map.put(existing, "major", updated_major)

    case write_config(global_path, updated) do
      :ok ->
        GiTF.Config.Provider.reload()
        :ok

      error ->
        error
    end
  end

  @doc """
  Merges `values` into one section of the config file the running factory
  actually reads, then reloads so the change takes effect without a
  restart.

  Two things separate this from `update_major_config/1`:

    * **It writes the winning layer, or nothing.** Load order is defaults
      → global → project → env, so a project `.gitf/config.toml` shadows
      the global file. Writing global while a project section exists
      would persist a value that never takes effect. This targets the
      resolved gitf root's config — the same file the dashboard's
      Settings page edits, so the two surfaces cannot disagree — and
      REFUSES when no root resolves. There is no global fallback on
      purpose: quietly rewriting `~/.config/gitf/config.toml` because a
      workspace could not be found is the kind of surprise a write tool
      must not have.
    * **It refuses to write over a config it could not parse.**
      `write_config/2` serialises the WHOLE map, so treating an
      unreadable file as `%{}` would replace an operator's entire config
      with the one section being set. A missing file is `%{}`; a corrupt
      one is an error.

  Callers should re-read the value through `GiTF.Config.Provider` rather
  than echoing what they wrote — an env var (`HIVE_*`) still outranks the
  file, and the effective value is the only honest receipt.
  """
  @spec update_config_section(String.t(), map()) :: :ok | {:error, term()}
  def update_config_section(section, values) when is_binary(section) and is_map(values) do
    with {:ok, path} <- writable_config_path(),
         {:ok, existing} <- read_existing_config(path) do
      merged = Map.merge(Map.get(existing, section, %{}), values)

      case write_config(path, Map.put(existing, section, merged)) do
        :ok ->
          GiTF.Config.Provider.reload()
          :ok

        error ->
          error
      end
    end
  end

  defp writable_config_path do
    case GiTF.gitf_dir() do
      {:ok, root} -> {:ok, Path.join([root, ".gitf", "config.toml"])}
      _ -> {:error, :no_gitf_root}
    end
  end

  defp read_existing_config(path) do
    if File.exists?(path) do
      case read_config(path) do
        {:ok, cfg} -> {:ok, cfg}
        {:error, reason} -> {:error, {:unreadable_config, path, reason}}
      end
    else
      {:ok, %{}}
    end
  end

  @doc """
  Returns true if the system is in dark factory mode (autonomous approval).
  """
  @spec dark_factory?() :: boolean()
  def dark_factory? do
    case GiTF.Config.Provider.get([:major, :dark_factory]) do
      val when is_boolean(val) -> val
      "true" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Returns the server URL from config, or nil if not configured.
  """
  @spec server_url() :: String.t() | nil
  def server_url do
    case GiTF.Config.Provider.get([:server, :url]) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    # Provider not started yet (e.g. early CLI boot)
    _ -> nil
  end

  @doc """
  Reads a top-level config value via Config.Provider (ETS-backed).

  Supports dotted keys like `:api_key` which maps to `[:server, :api_key]`.
  Returns nil if not found.
  """
  @spec get(atom()) :: term() | nil
  def get(key) do
    GiTF.Config.Provider.get(config_path(key))
  rescue
    _ -> nil
  end

  @doc """
  The API key shared by the HTTP server and remote CLI: `GITF_API_KEY` env,
  falling back to `[server] api_key` in config.toml. Single resolution chain
  so client and server can never disagree about which key is live.
  """
  @spec api_key() :: String.t() | nil
  def api_key do
    case System.get_env("GITF_API_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> get(:api_key)
    end
  end

  defp config_path(:api_key), do: [:server, :api_key]
  defp config_path(:max_ghosts), do: [:major, :max_ghosts]
  defp config_path(:budget_usd), do: [:costs, :budget_usd]
  defp config_path(:spawn_timeout_ms), do: [:ghost, :spawn_timeout_ms]
  defp config_path(:patrol_interval_ms), do: [:tachikoma, :patrol_interval_ms]
  defp config_path(:archive_prune_age_hours), do: [:tachikoma, :archive_prune_age_hours]
  defp config_path(:cost_retention_hours), do: [:tachikoma, :cost_retention_hours]
  defp config_path(:artifact_compact_days), do: [:tachikoma, :artifact_compact_days]
  defp config_path(:pattern_retention_max), do: [:tachikoma, :pattern_retention_max]
  defp config_path(_key), do: []

  # -- Private: TOML encoding ------------------------------------------------

  # We encode a simple two-level map to TOML by hand rather than pulling in a
  # TOML encoder dependency. The config structure is intentionally shallow.

  defp encode_toml(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n", &encode_section/1)
  end

  defp encode_section({section, values}) when is_map(values) do
    # Separate flat values from nested subsections (maps of maps)
    {flat, nested} =
      values
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.split_with(fn {_key, value} ->
        not (is_map(value) and Enum.any?(value, fn {_k, v} -> is_map(v) end))
      end)

    header = "[#{section}]"

    body =
      Enum.map_join(flat, "\n", fn {key, value} ->
        "#{key} = #{encode_value(value)}"
      end)

    subsections =
      Enum.map_join(nested, "\n", fn {key, sub_map} ->
        Enum.map_join(sub_map, "\n", fn {sub_key, sub_values} ->
          encode_section({"#{section}.#{key}.#{sub_key}", sub_values})
        end)
      end)

    parts = [if(body != "", do: "#{header}\n#{body}\n"), if(subsections != "", do: subsections)]
    parts |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp encode_value(value) when is_binary(value), do: ~s("#{value}")
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(value) when is_boolean(value), do: Atom.to_string(value)

  # Toml.decode returns structs for datetime literals; the generic is_map
  # clause serialized them as `{ __struct__ = ... }`, corrupting the file
  # on the next `gitf use`/`gitf login` round-trip. nil crashed outright.
  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(%Date{} = value), do: Date.to_iso8601(value)
  defp encode_value(%Time{} = value), do: Time.to_iso8601(value)
  defp encode_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_value(nil), do: ~s("")

  defp encode_value(value) when is_map(value) do
    entries = Enum.map_join(value, ", ", fn {k, v} -> "#{k} = #{encode_value(v)}" end)
    "{ #{entries} }"
  end

  defp encode_value(value) when is_list(value) do
    entries = Enum.map_join(value, ", ", &encode_value/1)
    "[#{entries}]"
  end
end
