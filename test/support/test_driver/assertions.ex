defmodule GiTF.TestDriver.Assertions do
  @moduledoc """
  Playwright-style auto-waiting assertions for E2E tests.

  All assertions poll with configurable timeout and interval,
  raising `ExUnit.AssertionError` with diagnostic info on failure.
  """

  alias GiTF.TestDriver.Recorder

  @default_timeout 10_000
  @default_interval 100

  @doc """
  Polls a condition until it becomes truthy or times out.

  ## Conditions

    * `{:job_done, op_id}` — op status is "done"
    * `{:job_failed, op_id}` — op status is "failed"
    * `{:quest_completed, mission_id}` — mission status is "completed"
    * `{:quest_failed, mission_id}` — mission status is "failed"
    * `{:bee_stopped, ghost_id}` — ghost status is "stopped" or "crashed"
    * `{:link_msg, filter}` — a link_msg matching the filter exists in Archive
    * `{:event, event_name}` — telemetry event exists in recorder timeline
    * `{:event, event_name, metadata}` — telemetry event with matching metadata
    * `{:store_count, collection, expected}` — collection has expected count
    * `fun/0` — arbitrary function returning truthy/falsy

  ## Options

    * `:timeout` — max wait time in ms (default: 10_000)
    * `:interval` — poll interval in ms (default: 100)
    * `:message` — custom failure message

  """
  @spec await(term(), keyword()) :: :ok
  def await(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await(condition, deadline, interval, message)
  end

  @doc """
  Asserts that a telemetry event with the given name exists in the recorder timeline.

  ## Options

    * `:metadata` — map of metadata fields to match
    * `:timeout` — max wait time (default: 5_000)

  """
  @spec assert_event(list(atom()), keyword()) :: :ok
  def assert_event(event_name, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    timeout = Keyword.get(opts, :timeout, 5_000)

    condition =
      if map_size(metadata) == 0 do
        {:event, event_name}
      else
        {:event, event_name, metadata}
      end

    await(condition,
      timeout: timeout,
      message:
        "Expected telemetry event #{inspect(event_name)} with metadata #{inspect(metadata)}"
    )
  end

  @doc """
  Asserts that a link_msg message matching the filter exists in the Archive.

  ## Filter keys

    * `:subject` — link_msg subject
    * `:from` — sender
    * `:to` — recipient

  """
  @spec assert_waggle(keyword()) :: :ok
  def assert_waggle(filter_and_opts) do
    {opts, filter} = extract_opts(filter_and_opts, [:timeout, :interval, :message])
    timeout = Keyword.get(opts, :timeout, 5_000)

    await({:link_msg, Map.new(filter)},
      timeout: timeout,
      message: "Expected link_msg matching #{inspect(filter)}"
    )
  end

  defp extract_opts(kw, opt_keys) do
    {opts, filter} =
      Enum.split_with(kw, fn {k, _v} -> k in opt_keys end)

    {opts, filter}
  end

  @doc """
  Asserts that a Archive collection has the expected number of records.
  """
  @spec assert_store_count(atom(), non_neg_integer(), keyword()) :: :ok
  def assert_store_count(collection, expected, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    await({:store_count, collection, expected},
      timeout: timeout,
      message: "Expected #{expected} records in #{collection}"
    )
  end

  # -- Private: polling loop ---------------------------------------------------

  defp do_await(condition, deadline, interval, message) do
    if check_condition(condition) do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        raise_timeout(condition, message)
      else
        Process.sleep(interval)
        do_await(condition, deadline, interval, message)
      end
    end
  end

  # -- Private: condition checking ---------------------------------------------

  defp check_condition({:job_done, op_id}) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{status: "done"}} -> true
      _ -> false
    end
  end

  defp check_condition({:job_failed, op_id}) do
    case GiTF.Ops.get(op_id) do
      {:ok, %{status: "failed"}} -> true
      _ -> false
    end
  end

  defp check_condition({:quest_completed, mission_id}) do
    case GiTF.Missions.get(mission_id) do
      {:ok, %{status: "completed"}} -> true
      _ -> false
    end
  end

  defp check_condition({:quest_failed, mission_id}) do
    case GiTF.Missions.get(mission_id) do
      {:ok, %{status: "failed"}} -> true
      _ -> false
    end
  end

  defp check_condition({:bee_stopped, ghost_id}) do
    case GiTF.Ghosts.get(ghost_id) do
      {:ok, %{status: status}} when status in ["stopped", "crashed"] -> true
      _ -> false
    end
  end

  defp check_condition({:link_msg, filter}) when is_map(filter) do
    links = GiTF.Archive.all(:links)

    Enum.any?(links, fn w ->
      Enum.all?(filter, fn {k, v} -> Map.get(w, k) == v end)
    end)
  end

  defp check_condition({:event, event_name}) do
    Recorder.events(type: :telemetry, event: event_name) != []
  rescue
    _ -> false
  end

  defp check_condition({:event, event_name, metadata}) do
    events = Recorder.events(type: :telemetry, event: event_name)

    Enum.any?(events, fn entry ->
      meta = get_in(entry, [:data, :metadata]) || %{}
      Enum.all?(metadata, fn {k, v} -> Map.get(meta, k) == v end)
    end)
  rescue
    _ -> false
  end

  defp check_condition({:store_count, collection, expected}) do
    GiTF.Archive.count(collection) == expected
  rescue
    _ -> false
  end

  defp check_condition(fun) when is_function(fun, 0) do
    fun.() |> truthy?()
  rescue
    _ -> false
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # -- Private: error reporting ------------------------------------------------

  defp raise_timeout(condition, custom_message) do
    timeline_summary = get_timeline_summary()

    default_msg = "Timed out waiting for condition: #{inspect(condition)}"
    msg = custom_message || default_msg

    full_message = """
    #{msg}

    == Recorder Timeline (last 20 entries) ==
    #{timeline_summary}
    """

    raise ExUnit.AssertionError, message: full_message
  end

  defp get_timeline_summary do
    entries =
      try do
        Recorder.timeline()
      rescue
        _ -> []
      end

    entries
    |> Enum.take(-20)
    |> Enum.map_join("\n", fn entry ->
      "  [#{entry.type}] #{inspect(entry.event)} — #{inspect_short(entry.data)}"
    end)
  end

  defp inspect_short(data) when is_map(data) do
    data
    |> Map.take([
      :collection,
      :action,
      :id,
      :subject,
      :from,
      :ghost_id,
      :op_id,
      :status,
      :metadata,
      :measurements
    ])
    |> inspect(limit: 5, printable_limit: 200)
  end

  defp inspect_short(data), do: inspect(data, limit: 5, printable_limit: 200)
end
