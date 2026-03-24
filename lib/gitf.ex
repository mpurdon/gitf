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

  Checks the GITF_PATH environment variable first, then walks up from the
  current working directory looking for a `.gitf/` directory marker.
  """
  @spec gitf_dir() :: {:ok, String.t()} | {:error, :not_in_gitf}
  def gitf_dir do
    case System.get_env("GITF_PATH") do
      nil -> find_gitf_dir(File.cwd!())
      path -> validate_gitf_path(Path.expand(path))
    end
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
