defmodule GiTF.Cabinet.Proxy do
  @moduledoc """
  Forwards one MCP tool call to a ministry's Section.

  The Cabinet is a router here, not an authority: the call is re-issued
  against the Section's own `/api/v1/mcp` with that Section's API key
  (resolved from the registry's env reference), and the Section's answer
  comes back verbatim. With `wake: true` the box is started and awaited
  first — that is how "create a mission on trajector" works from a phone
  while the whole fleet sleeps.
  """

  alias GiTF.Cabinet.{Fleet, Registry}

  @doc "Calls `tool` with `args` on the ministry's Section. Returns {:ok, result_text} | {:error, reason}."
  def call(slug, tool, args, opts \\ []) do
    with %{} = ministry <- Registry.by_slug(slug) || {:error, :unknown_ministry},
         url when is_binary(url) and url != "" <- ministry[:url] || {:error, :no_url},
         :ok <- maybe_wake(ministry, Keyword.get(opts, :wake, false)) do
      request(ministry, url, tool, args)
    end
  end

  defp maybe_wake(ministry, true), do: Fleet.wake_and_await(ministry)
  defp maybe_wake(_ministry, false), do: :ok

  defp request(ministry, url, tool, args) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: tool, arguments: args || %{}}
    }

    headers =
      case api_key(ministry) do
        nil -> []
        key -> [{"x-api-key", key}]
      end

    case Req.post(
           url: String.trim_trailing(url, "/") <> "/api/v1/mcp",
           json: body,
           headers: headers,
           retry: false,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: %{"result" => %{"content" => content}}}} ->
        {:ok, content |> List.wrap() |> Enum.map_join("\n", &(&1["text"] || ""))}

      {:ok, %{status: 200, body: %{"error" => err}}} ->
        {:error, {:rpc, err}}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "" do
    case System.get_env(env) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp api_key(_), do: nil
end
