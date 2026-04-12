defmodule GiTF.Config.Provider do
  @moduledoc """
  Runtime config precedence chain.

  Load order: defaults -> global config (`~/.config/gitf/config.toml`) ->
  project config (`.gitf/config.toml`) -> env vars (`HIVE_*`) -> CLI flags.
  Each layer merges over the previous. Config available via `get/1`.

  Supports env var interpolation in TOML values: `token = "${HIVE_TELEGRAM_TOKEN}"`
  """

  use GenServer

  @table :gitf_config

  # -- Public API ------------------------------------------------------------

  @doc "Starts the config provider."
  @spec start_link(keyword()) :: GenServer.on_start()
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

  @doc """
  Reloads config from all sources and broadcasts `{:config_reloaded, changed_keys}`
  on the `"config:reloaded"` PubSub topic so running services can react.

  Processes that need to pick up config changes should subscribe:

      Phoenix.PubSub.subscribe(GiTF.PubSub, "config:reloaded")

  and handle:

      def handle_info({:config_reloaded, changed_keys}, state)
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Subscribe the calling process to config reload notifications."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(GiTF.PubSub, "config:reloaded")
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
    old_config =
      case :ets.lookup(@table, :config) do
        [{:config, c}] -> c
        [] -> %{}
      end

    new_config = load_config(state.gitf_root)
    :ets.insert(@table, {:config, new_config})

    changed_keys = diff_top_keys(old_config, new_config)

    if changed_keys != [] do
      Phoenix.PubSub.broadcast(
        GiTF.PubSub,
        "config:reloaded",
        {:config_reloaded, changed_keys}
      )
    end

    {:reply, :ok, state}
  end

  # -- Private ---------------------------------------------------------------

  defp load_config(gitf_root) do
    defaults()
    |> deep_merge(load_global_toml())
    |> deep_merge_non_empty(load_project_toml(gitf_root))
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
      exfil: %{
        drain_timeout_ms: 5_000
      }
    }
  end

  defp load_global_toml do
    load_toml_file(GiTF.global_config_path())
  end

  defp load_project_toml(nil), do: %{}

  defp load_project_toml(gitf_root) do
    load_toml_file(Path.join([gitf_root, ".gitf", "config.toml"]))
  end

  defp load_toml_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, parsed} -> parsed |> interpolate_env() |> strip_empty_strings() |> atomize_keys()
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
        |> Enum.map(fn segment ->
          # Use existing atoms only — prevents atom table exhaustion from
          # arbitrary env var names on repeated config reloads
          try do
            String.to_existing_atom(segment)
          rescue
            ArgumentError -> segment
          end
        end)

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

  # Normalize empty strings to nil so downstream code doesn't need != "" guards
  defp strip_empty_strings(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, strip_empty_strings(v)} end)
  end

  defp strip_empty_strings(""), do: nil
  defp strip_empty_strings(list) when is_list(list), do: Enum.map(list, &strip_empty_strings/1)
  defp strip_empty_strings(value), do: value

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

  # Project overlay: skip nil values so unset project keys don't clobber global config
  defp deep_merge_non_empty(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, l, r when is_map(l) and is_map(r) -> deep_merge_non_empty(l, r)
      _key, l, nil -> l
      _key, _l, r -> r
    end)
  end

  defp deep_merge_non_empty(_left, right), do: right

  # Returns the list of top-level keys whose values changed between two configs.
  defp diff_top_keys(old, new) when is_map(old) and is_map(new) do
    all_keys = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))

    Enum.filter(all_keys, fn k -> Map.get(old, k) != Map.get(new, k) end)
  end

  defp diff_top_keys(_, _), do: []
end
