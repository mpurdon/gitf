defmodule GiTF.Runtime.Ollama do
  @moduledoc """
  Manager for the local Ollama service.
  """

  require Logger

  @default_url "http://localhost:11434"

  @doc "Checks if the Ollama server is running."
  def running? do
    url = System.get_env("OLLAMA_BASE_URL") || @default_url

    case Req.get(url, retry: false, receive_timeout: 1000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc "Starts the Ollama server."
  def start_server do
    if running?() do
      {:ok, :already_running}
    else
      path = System.find_executable("ollama")

      if is_nil(path) do
        {:error, :not_installed}
      else
        try do
          # Spawn as a detached process so it doesn't die when GitF exits (unless running in TUI, but even then).
          Task.start(fn ->
            System.cmd(path, ["serve"])
          end)

          case wait_for_startup(20) do
            :ok -> {:ok, :started}
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, e}
        end
      end
    end
  end

  defp wait_for_startup(0), do: {:error, :timeout}

  defp wait_for_startup(retries) do
    if running?() do
      :ok
    else
      Process.sleep(500)
      wait_for_startup(retries - 1)
    end
  end

  @doc "Lists available models in the local Ollama instance."
  def list_models do
    url = (System.get_env("OLLAMA_BASE_URL") || @default_url) <> "/api/tags"

    case Req.get(url, receive_timeout: 5000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["name"])}

      _ ->
        {:error, :unavailable}
    end
  end
end
