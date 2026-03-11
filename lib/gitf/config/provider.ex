defmodule GiTF.Config.Provider do
  @moduledoc """
  Runtime config precedence chain.

  Load order: defaults -> `.gitf/config.toml` -> env vars (`HIVE_*`) -> CLI flags.
  Each layer merges over the previous. Config available via `get/1`.

  Supports env var interpolation in TOML values: `token = "${HIVE_TELEGRAM_TOKEN}"`
  """

  use GenServer

  @table :gitf_config

  # -- Public API ------------------------------------------------------------

  @doc "Starts the config provider."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Gets a config value by path (list of keys)."
  @spec get(list(atom())) :: term()
  def get(path) when is_list(path) do
    case :ets.lookup(@table, :config) do
      [{:config, config}] -> get_in(config, path)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Gets a config value with a default."
  @spec get(list(atom()), term()) :: term()
  def get(path, default) do
    get(path) || default
  end

  @doc "Reloads config from all sources."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    gitf_root = Keyword.get(opts, :gitf_root)
    config = load_config(gitf_root)
    :ets.insert(@table, {:config, config})
    {:ok, %{gitf_root: gitf_root}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    config = load_config(state.gitf_root)
    :ets.insert(@table, {:config, config})
    {:reply, :ok, state}
  end

  # -- Private ---------------------------------------------------------------

  defp load_config(gitf_root) do
    defaults()
    |> deep_merge(load_toml(gitf_root))
    |> deep_merge(load_env())
  end

  defp defaults do
    %{
      plugins: %{
        channels: %{},
        mcp: %{},
        models: %{default: "reqllm", providers: %{}},
        themes: %{default: "default"}
      },
      queen: %{
        max_ghosts: 5,
        max_retries: 3
      },
      shutdown: %{
        drain_timeout_ms: 5_000
      }
    }
  end

  defp load_toml(nil), do: %{}

  defp load_toml(gitf_root) do
    path = Path.join([gitf_root, ".gitf", "config.toml"])

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, parsed} -> atomize_keys(interpolate_env(parsed))
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp load_env do
    System.get_env()
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "HIVE_") end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      path =
        key
        |> String.downcase()
        |> String.split("_")
        |> Enum.drop(1)
        |> Enum.map(&String.to_atom/1)

      put_nested(acc, path, value)
    end)
  end

  defp interpolate_env(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, interpolate_env(v)} end)
  end

  defp interpolate_env(value) when is_binary(value) do
    Regex.replace(~r/\$\{(\w+)\}/, value, fn _, var_name ->
      System.get_env(var_name) || ""
    end)
  end

  defp interpolate_env(value), do: value

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    inner = Map.get(map, key, %{})
    Map.put(map, key, put_nested(inner, rest, value))
  end

  defp put_nested(map, [], _value), do: map

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, l, r when is_map(l) and is_map(r) -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp deep_merge(_left, right), do: right
end
