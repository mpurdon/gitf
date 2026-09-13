defmodule GiTF.Cabinet.Remote do
  @moduledoc """
  Reads a ministry's factory over the tailnet, as data.

  `Proxy` re-issues MCP tool calls and hands back the Section's prose; that is
  the right shape for "do this thing", and the wrong shape for "show me what is
  there". The Console needs sectors, missions and ops as maps it can put in a
  tree, so this reads the factory's JSON API directly.

  ## Asleep is an answer, not a failure

  A ministry's box powers itself off when idle, and most of the time the honest
  answer to "what sectors does it have?" is "it is asleep, and finding out costs
  a minute and some money". So a box that is not running returns `{:error,
  :asleep}` **without a request** — the Cabinet already knows the instance
  state, and a doomed 120-second connect would only turn a fact into a timeout.
  Waking is something an operator asks for; it is never a side effect of
  expanding a row in a tree.
  """

  alias GiTF.Cabinet.Registry

  # Reading is not doing. A factory that cannot answer a GET in a few seconds
  # is one whose tree can say so and offer a retry, which beats a rail that
  # hangs.
  @timeout_ms 8_000

  @type reason :: :asleep | :unknown_ministry | :no_url | {:status, pos_integer()} | term()

  @doc """
  GETs `path` (e.g. `"/sectors"`) from the ministry's factory API.

  Returns the decoded `data` member, because every endpoint on that API wraps
  its payload in one and a caller that has to remember is a caller that will
  forget.
  """
  @spec get(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, reason()}
  def get(slug, path, opts \\ []) do
    with %{} = ministry <- Registry.by_slug(slug) || {:error, :unknown_ministry},
         :ok <- awake?(ministry),
         url when is_binary(url) and url != "" <- ministry[:url] || {:error, :no_url} do
      request(ministry, url, path, opts)
    end
  end

  @doc """
  The ministry's sectors, missions and ops in one go.

  One round of three parallel requests rather than three rounds: the tree shows
  all three depths at once, and a rail that fills in over three seconds reads as
  broken even when every request succeeds.
  """
  @spec browse(String.t()) :: {:ok, map()} | {:error, reason()}
  def browse(slug) do
    with %{} = ministry <- Registry.by_slug(slug) || {:error, :unknown_ministry},
         :ok <- awake?(ministry) do
      [sectors, missions, ops] =
        ["/sectors", "/missions?all=true", "/ops?all=true"]
        |> Enum.map(fn path -> Task.async(fn -> get(slug, path) end) end)
        |> Task.await_many(@timeout_ms + 2_000)

      {:ok,
       %{
         sectors: list_or_empty(sectors),
         missions: list_or_empty(missions),
         ops: list_or_empty(ops),
         at: DateTime.utc_now(),
         partial?: Enum.any?([sectors, missions, ops], &match?({:error, _}, &1))
       }}
    end
  end

  defp list_or_empty({:ok, list}) when is_list(list), do: list
  defp list_or_empty(_), do: []

  # A lookup, never a probe: the Cabinet's watcher already records instance
  # state, and asking EC2 here would put an `aws` subprocess on the read path of
  # every page — slow where the CLI exists and a crash where it does not.
  #
  # A state we have not recorded is treated as awake, because not knowing is a
  # reason to ask the factory, not a reason to tell the operator it is asleep.
  defp awake?(ministry) do
    case ministry[:box][:state] do
      "running" -> :ok
      state when state in [nil, :unknown] -> :ok
      _ -> {:error, :asleep}
    end
  end

  defp request(ministry, url, path, opts) do
    headers =
      case api_key(ministry) do
        nil -> []
        key -> [{"x-api-key", key}]
      end

    case Req.get(
           url: String.trim_trailing(url, "/") <> "/api/v1" <> path,
           headers: headers,
           retry: false,
           receive_timeout: Keyword.get(opts, :timeout_ms, @timeout_ms)
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, atomize(data)}
      {:ok, %{status: 200, body: body}} -> {:ok, atomize(body)}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The rest of the Console reads atom keys, so the boundary converts once
  # rather than every page remembering which side of the wire it is on.
  # `to_existing_atom` keeps a hostile or merely unexpected factory from
  # growing the atom table.
  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)

  defp atomize(%{} = map) do
    Map.new(map, fn {key, value} -> {safe_atom(key), atomize(value)} end)
  end

  defp atomize(other), do: other

  defp safe_atom(key) when is_atom(key), do: key

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "" do
    case System.get_env(env) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp api_key(_), do: nil
end
