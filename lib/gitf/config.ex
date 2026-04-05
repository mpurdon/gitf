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
    "major" => %{"max_ghosts" => 5},
    "ghost" => %{"spawn_timeout_ms" => 30_000},
    "tachikoma" => %{
      "patrol_interval_ms" => 30_000,
      "archive_prune_age_hours" => 48
    },
    "costs" => %{"warn_threshold_usd" => 5.0, "budget_usd" => 10.0},
    "llm" => %{"keys" => %{"google" => "", "anthropic" => ""}},
    "github" => %{"token" => ""},
    "server" => %{"url" => ""},
    "observability" => %{"webhook_url" => ""}
  }

  @project_default_config %{
    "gitf" => %{"version" => GiTF.version()},
    "session" => %{"current_sector" => ""}
  }

  @default_config Map.merge(@global_default_config, @project_default_config)

  @doc "Returns the default global configuration map (API keys, budgets, thresholds)."
  @spec global_default_config() :: map()
  def global_default_config, do: @global_default_config

  @doc "Returns the default project configuration map (version, session)."
  @spec project_default_config() :: map()
  def project_default_config, do: @project_default_config

  @doc """
  Returns the full default configuration map (global + project merged).

  ## Examples

      iex> config = GiTF.Config.default_config()
      iex> config["major"]["max_ghosts"]
      5
  """
  @spec default_config() :: map()
  def default_config, do: @default_config

  @doc """
  Writes a configuration map to the given file path as TOML.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write_config(String.t(), map()) :: :ok | {:error, term()}
  def write_config(path, config \\ @default_config) do
    content = encode_toml(config)
    File.write(path, content)
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

  defp config_path(:api_key), do: [:server, :api_key]
  defp config_path(:max_ghosts), do: [:major, :max_ghosts]
  defp config_path(:budget_usd), do: [:costs, :budget_usd]
  defp config_path(:spawn_timeout_ms), do: [:ghost, :spawn_timeout_ms]
  defp config_path(:patrol_interval_ms), do: [:tachikoma, :patrol_interval_ms]
  defp config_path(:archive_prune_age_hours), do: [:tachikoma, :archive_prune_age_hours]
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

  defp encode_value(value) when is_map(value) do
    entries = Enum.map_join(value, ", ", fn {k, v} -> "#{k} = #{encode_value(v)}" end)
    "{ #{entries} }"
  end

  defp encode_value(value) when is_list(value) do
    entries = Enum.map_join(value, ", ", &encode_value/1)
    "[#{entries}]"
  end
end
