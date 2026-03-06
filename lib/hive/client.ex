defmodule Hive.Client do
  @moduledoc """
  HTTP client for remote Hive server.

  When `HIVE_SERVER` is set (or `[server] url` in config.toml), CLI commands
  talk to the remote server over HTTP instead of calling context modules directly.
  """

  @doc "Returns true when the CLI should operate in remote mode."
  def remote?, do: server_url() != nil

  @doc "Returns the server URL or nil for local mode."
  def server_url do
    case System.get_env("HIVE_SERVER") do
      nil -> Hive.Config.server_url()
      "" -> Hive.Config.server_url()
      url -> url
    end
  end

  # -- HTTP primitives ---------------------------------------------------------

  def get(path, opts \\ []) do
    url = build_url(path)
    params = Keyword.get(opts, :params, [])

    Req.get(url, params: params)
    |> handle_response()
  end

  def post(path, body \\ %{}, _opts \\ []) do
    url = build_url(path)

    Req.post(url, json: body)
    |> handle_response()
  end

  def put(path, body \\ %{}, _opts \\ []) do
    url = build_url(path)

    Req.put(url, json: body)
    |> handle_response()
  end

  def delete(path, _opts \\ []) do
    url = build_url(path)

    Req.delete(url)
    |> handle_response()
  end

  # -- Domain helpers (match context module APIs) ------------------------------

  # Quests
  def create_quest(attrs), do: post("/api/v1/quests", attrs) |> unwrap_data()
  def list_quests(opts \\ []), do: get("/api/v1/quests", params: opts) |> unwrap_data()
  def get_quest(id), do: get("/api/v1/quests/#{id}") |> unwrap_data()
  def delete_quest(id), do: delete("/api/v1/quests/#{id}") |> unwrap_ok()
  def close_quest(id), do: post("/api/v1/quests/#{id}/close") |> unwrap_data()
  def start_quest(id), do: post("/api/v1/quests/#{id}/start") |> unwrap_data()
  def quest_status(id), do: get("/api/v1/quests/#{id}/status") |> unwrap_data()
  def plan_quest(id), do: post("/api/v1/quests/#{id}/plan") |> unwrap_data()

  # Jobs
  def list_jobs(opts \\ []), do: get("/api/v1/jobs", params: opts) |> unwrap_data()
  def get_job(id), do: get("/api/v1/jobs/#{id}") |> unwrap_data()
  def reset_job(id), do: post("/api/v1/jobs/#{id}/reset") |> unwrap_data()

  # Bees
  def list_bees, do: get("/api/v1/bees") |> unwrap_data()
  def stop_bee(id), do: post("/api/v1/bees/#{id}/stop") |> unwrap_ok()
  def complete_bee(id), do: post("/api/v1/bees/#{id}/complete") |> unwrap_ok()
  def fail_bee(id, reason \\ "unknown"), do: post("/api/v1/bees/#{id}/fail", %{reason: reason}) |> unwrap_ok()

  # Combs
  def add_comb(path_or_url, opts \\ []) do
    post("/api/v1/combs", %{path: path_or_url, opts: Map.new(opts)}) |> unwrap_data()
  end

  def list_combs, do: get("/api/v1/combs") |> unwrap_data()
  def get_comb(id), do: get("/api/v1/combs/#{id}") |> unwrap_data()
  def remove_comb(id), do: delete("/api/v1/combs/#{id}") |> unwrap_ok()
  def use_comb(id), do: post("/api/v1/combs/#{id}/use") |> unwrap_data()

  # Quest extras
  def quest_report(id), do: get("/api/v1/quests/#{id}/report") |> unwrap_data()
  def quest_merge(id), do: post("/api/v1/quests/#{id}/merge") |> unwrap_data()
  def quest_spec(id, phase), do: get("/api/v1/quests/#{id}/spec/#{phase}") |> unwrap_data()
  def quest_spec_write(id, phase, content), do: put("/api/v1/quests/#{id}/spec/#{phase}", %{content: content}) |> unwrap_data()

  # Plan confirmation
  def confirm_plan(quest_id, specs), do: post("/api/v1/quests/#{quest_id}/plan/confirm", %{specs: specs}) |> unwrap_data()
  def reject_plan(quest_id), do: post("/api/v1/quests/#{quest_id}/plan/reject") |> unwrap_ok()
  def revise_plan(quest_id, feedback), do: post("/api/v1/quests/#{quest_id}/plan/revise", %{feedback: feedback}) |> unwrap_data()
  def list_plan_candidates(quest_id), do: get("/api/v1/quests/#{quest_id}/plan/candidates") |> unwrap_data()
  def select_plan_candidate(quest_id, strategy), do: post("/api/v1/quests/#{quest_id}/plan/select", %{strategy: strategy}) |> unwrap_data()

  # Costs
  def costs_summary, do: get("/api/v1/costs/summary") |> unwrap_data()
  def record_cost(bee_id, attrs), do: post("/api/v1/costs/record", Map.put(attrs, :bee_id, bee_id)) |> unwrap_data()

  # Health check
  def ping do
    case get("/api/v1/health") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Internals ---------------------------------------------------------------

  defp build_url(path) do
    base = server_url() |> String.trim_trailing("/")
    base <> path
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: 404}}) do
    {:error, :not_found}
  end

  defp handle_response({:ok, %Req.Response{body: %{"error" => msg}}}) do
    {:error, msg}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    {:error, "server returned #{status}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: :econnrefused}}) do
    {:error, "Cannot reach server. Is it running?"}
  end

  defp handle_response({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, "Connection timed out."}
  end

  defp handle_response({:error, %Req.TransportError{reason: :nxdomain}}) do
    {:error, "Server hostname not found."}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}) do
    {:error, "Connection failed: #{inspect(reason)}"}
  end

  defp handle_response({:error, reason}) do
    {:error, "Request failed: #{inspect(reason)}"}
  end

  defp unwrap_data({:ok, %{"data" => data}}), do: {:ok, atomize(data)}
  defp unwrap_data({:error, _} = err), do: err
  defp unwrap_data({:ok, body}), do: {:ok, body}

  defp unwrap_ok({:ok, _}), do: :ok
  defp unwrap_ok({:error, _} = err), do: err

  defp atomize(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {safe_atom(k), atomize(v)} end)
  end

  defp atomize(data) when is_list(data), do: Enum.map(data, &atomize/1)
  defp atomize(data), do: data

  defp safe_atom(k) when is_atom(k), do: k
  defp safe_atom(k) when is_binary(k), do: String.to_atom(k)
end
