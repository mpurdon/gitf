defmodule GiTF.Config do
  @moduledoc """
  Reads, writes, and provides defaults for the `.gitf/config.toml` configuration file.

  The config is a small TOML file that lives inside the `.gitf/` directory and
  controls section-wide settings such as maximum concurrent ghosts and cost thresholds.
  """

  @default_config %{
    "gitf" => %{"version" => GiTF.version()},
    "major" => %{"max_ghosts" => 5},
    "costs" => %{"warn_threshold_usd" => 5.0, "budget_usd" => 10.0},
    "llm" => %{"keys" => %{"google" => "", "anthropic" => ""}},
    "github" => %{"token" => ""},
    "server" => %{"url" => ""},
    "session" => %{"current_comb" => ""}
  }

  @doc """
  Returns the default configuration map.

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
  Returns the server URL from .gitf/config.toml, or nil if not configured.
  """
  @spec server_url() :: String.t() | nil
  def server_url do
    with {:ok, root} <- GiTF.gitf_dir(),
         {:ok, config} <- read_config(Path.join([root, ".gitf", "config.toml"])),
         url when is_binary(url) and url != "" <- get_in(config, ["server", "url"]) do
      url
    else
      _ -> nil
    end
  end

  @doc """
  Reads a top-level config value from .gitf/config.toml.

  Supports dotted keys like `:api_key` which maps to `["server", "api_key"]`.
  Returns nil if not found or config can't be read.
  """
  @spec get(atom()) :: term() | nil
  def get(key) do
    with {:ok, root} <- GiTF.gitf_dir(),
         {:ok, config} <- read_config(Path.join([root, ".gitf", "config.toml"])) do
      config_lookup(config, key)
    else
      _ -> nil
    end
  end

  defp config_lookup(config, :api_key), do: get_in(config, ["server", "api_key"])
  defp config_lookup(config, :max_ghosts), do: get_in(config, ["major", "max_ghosts"])
  defp config_lookup(config, :budget_usd), do: get_in(config, ["costs", "budget_usd"])
  defp config_lookup(_config, _key), do: nil

  # -- Private: TOML encoding ------------------------------------------------

  # We encode a simple two-level map to TOML by hand rather than pulling in a
  # TOML encoder dependency. The config structure is intentionally shallow.

  defp encode_toml(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n", &encode_section/1)
  end

  defp encode_section({section, values}) when is_map(values) do
    header = "[#{section}]"

    body =
      values
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join("\n", fn {key, value} ->
        "#{key} = #{encode_value(value)}"
      end)

    "#{header}\n#{body}\n"
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
