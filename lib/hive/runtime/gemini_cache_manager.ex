defmodule Hive.Runtime.GeminiCacheManager do
  @moduledoc """
  Manager for Google Gemini Context Caching.

  Gemini requires creating a stateful `cachedContent` resource via the API
  before it can be used in generation requests. This module handles:
  1. Hashing content (e.g. system prompts) to identify unique caches.
  2. Checking if a valid cache exists.
  3. Creating new caches via `ReqLLM` or direct API calls.
  4. returning the `cachedContent` resource name to be passed to the model.

  ## Usage (Proposed)

      case GeminiCacheManager.get_or_create(system_prompt, model, ttl_seconds: 3600) do
        {:ok, cache_name} ->
          # Pass cache_name to ReqLLM in a special field
          ReqLLM.generate_text(model, messages, cached_content: cache_name)
        {:error, _} ->
          # Fallback to standard request
      end
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{caches: %{}}}
  end

  @doc """
  Gets an existing cache name or creates a new one for the given content.
  """
  def get_or_create(content, model, opts \\ []) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16()
    GenServer.call(__MODULE__, {:get_or_create, hash, content, model, opts})
  end

  @impl true
  def handle_call({:get_or_create, hash, content, model, opts}, _from, state) do
    # Check if we have a valid cache
    case Map.get(state.caches, hash) do
      %{name: name, expires_at: expires_at} ->
        if DateTime.diff(expires_at, DateTime.utc_now()) > 30 do
          # Cache valid (>30s remaining)
          {:reply, {:ok, name}, state}
        else
          # Cache expired or expiring soon, create new one
          create_and_store(hash, content, model, opts, state)
        end
        
      nil ->
        # No cache, create one
        create_and_store(hash, content, model, opts, state)
    end
  end

  defp create_and_store(hash, content, model, opts, state) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 3600)
    
    # Map friendly model name to API model name if needed
    # e.g. "google:gemini-1.5-pro" -> "models/gemini-1.5-pro-001"
    # For now, assume model is passed correctly or perform basic mapping
    api_model = map_to_api_model(model)

    case create_cache_resource(content, api_model, ttl_seconds) do
      {:ok, %{"name" => name, "expireTime" => expire_time}} ->
        {:ok, expires_at, _} = DateTime.from_iso8601(expire_time)
        
        new_caches = Map.put(state.caches, hash, %{
          name: name,
          expires_at: expires_at,
          model: model
        })
        
        Logger.info("Created Gemini Context Cache: #{name} (expires #{expire_time})")
        {:reply, {:ok, name}, %{state | caches: new_caches}}

      {:error, reason} ->
        Logger.warning("Failed to create Gemini cache: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  defp create_cache_resource(system_instruction, model, ttl_seconds) do
    key = get_api_key()
    url = "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=#{key}"
    
    body = %{
      "model" => model,
      "systemInstruction" => %{
        "parts" => [%{"text" => system_instruction}]
      },
      "ttl" => "#{ttl_seconds}s"
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "API #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_api_key do
    # Try to find key in config or env
    System.get_env("GOOGLE_API_KEY") ||
      Application.get_env(:req_llm, :google_api_key) ||
      raise "GOOGLE_API_KEY not found"
  end

  defp map_to_api_model(model) do
    # Handle "google:gemini-1.5-pro" -> "models/gemini-1.5-pro-001"
    # Basic heuristic: if it contains "gemini", ensure it starts with "models/"
    # and strip "google:" prefix
    
    clean = String.replace(model, "google:", "")
    
    if String.starts_with?(clean, "models/") do
      clean
    else
      "models/#{clean}"
    end
  end
end
