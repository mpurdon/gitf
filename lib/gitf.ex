defmodule GiTF do
  @moduledoc "The GiTF - Multi-agent orchestration for AI coding assistants."

  @spec version() :: String.t()
  def version do
    case :persistent_term.get(:gitf_version, nil) do
      nil ->
        v = read_version()
        :persistent_term.put(:gitf_version, v)
        v

      v ->
        v
    end
  end

  @doc "Bust the cached version (call after mix.exs changes in dev)."
  def reload_version do
    :persistent_term.put(:gitf_version, read_version())
  end

  defp read_version do
    case File.read("mix.exs") do
      {:ok, content} ->
        case Regex.run(~r/@version "([^"]+)"/, content) do
          [_, v] -> v
          _ -> Application.spec(:gitf, :vsn) |> to_string()
        end

      _ ->
        Application.spec(:gitf, :vsn) |> to_string()
    end
  end

  # -- Global config paths ----------------------------------------------------

  @doc "Returns the global config directory: ~/.config/gitf/"
  @spec global_config_dir() :: String.t()
  def global_config_dir do
    Path.join([System.user_home!(), ".config", "gitf"])
  end

  @doc "Returns the global config file path: ~/.config/gitf/config.toml"
  @spec global_config_path() :: String.t()
  def global_config_path do
    Path.join(global_config_dir(), "config.toml")
  end

  # -- Project discovery ------------------------------------------------------

  @doc """
  Locates the root directory of a GiTF project.

  Resolution order:
    1. `GITF_PATH` environment variable (set by `-w` / `--workspace` flag)
    2. Walk up from cwd looking for `.gitf/` (workspace-local, legacy)
    3. `${GITF_HOME:-~/.gitf}` parent (single-user homedir mode, default)

  In homedir mode the "root" is `$HOME` and `.gitf/` lives directly under it.
  """
  @spec gitf_dir() :: {:ok, String.t()} | {:error, :not_in_gitf}
  def gitf_dir do
    case System.get_env("GITF_PATH") do
      nil ->
        case find_gitf_dir(File.cwd!()) do
          {:ok, path} -> {:ok, path}
          {:error, :not_in_gitf} -> homedir_root()
        end

      path ->
        validate_gitf_path(Path.expand(path))
    end
  end

  @doc """
  Returns the parent directory whose `.gitf/` is the homedir-mode store.

  Resolves `GITF_HOME` if set, else `$HOME`. Returns `{:ok, parent}` when
  `<parent>/.gitf/config.toml` exists, else `{:error, :not_in_gitf}`.
  """
  @spec homedir_root() :: {:ok, String.t()} | {:error, :not_in_gitf}
  def homedir_root do
    parent = System.get_env("GITF_HOME") || System.user_home!()
    validate_gitf_path(parent)
  end

  defp validate_gitf_path(expanded) do
    if initialized?(expanded),
      do: {:ok, expanded},
      else: {:error, :not_in_gitf}
  end

  defp find_gitf_dir("/"), do: {:error, :not_in_gitf}

  defp find_gitf_dir(path) do
    if initialized?(path),
      do: {:ok, path},
      else: find_gitf_dir(Path.dirname(path))
  end

  defp initialized?(path) do
    File.exists?(Path.join([path, ".gitf", "config.toml"]))
  end
end
