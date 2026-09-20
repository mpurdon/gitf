defmodule GiTF.Config.Settable do
  @moduledoc """
  Which configuration keys may be changed from a chat surface, and which
  may never be.

  The Discord personas can reach this through one MCP tool. That makes the
  allow-list a security boundary, not a convenience: a key reachable from
  Discord is a key reachable by anyone who compromises a Discord account, so
  the list is **deny by default** and every entry had to earn its place.

  Three classes are excluded on principle:

    * **Secrets.** API keys, webhook secrets, tokens, the server API key.
      These live in `/etc/gitf/gitf.env`, rendered from SSM Parameter Store
      at boot, and must never transit a third-party chat service. The
      pattern check in `secret_shaped?/1` is defence in depth behind the
      allow-list, not the primary gate.
    * **Anything that changes what is billed.** Spend caps, `execution_mode`
      (which picks subscription vs metered), model tiers. Raising a ceiling
      is a spending decision; it belongs where there is person-level identity,
      not in a chat message.
    * **Anything that changes who may act.** Operator lists, guild ids, auth
      settings — changing them from a chat surface would let that surface
      widen its own access.

  What remains is operational: feature flags, admission policy, and the
  routing maps that say which project maps to which sector. Those are the
  things an operator actually needs to change at 11pm from a phone.
  """

  @typedoc "A dotted config path, e.g. `\"features.aramaki_enabled\"`."
  @type key :: String.t()

  # Deny by default. Each entry: {dotted key, kind, one-line description}.
  # `kind` drives coercion and validation of the supplied value.
  @settable %{
    # -- Feature flags ---------------------------------------------------
    "features.aramaki_enabled" => {:boolean, "Admit issues/tickets/alerts as missions"},
    "features.outcomes_enabled" => {:boolean, "Track what happened to published PRs"},
    "features.outcome_refinement_enabled" => {:boolean, "Feed outcomes back into skills"},
    "features.skills_enabled" => {:boolean, "Retrieve and install learned skills"},
    "features.skill_refinement_enabled" => {:boolean, "Propose new skills after validation"},
    "features.knowledge_context_enabled" => {:boolean, "Inject wiki pages into phase prompts"},
    "features.workflow_inference_enabled" =>
      {:boolean, "Infer the workflow template from the goal"},
    "features.wire_enabled" => {:boolean, "Use Wire notation in phase prompts"},
    "features.triage_enabled" => {:boolean, "Triage ops before planning"},
    "features.visual_capture_enabled" => {:boolean, "Capture screenshots during validation"},

    # -- Admission policy -------------------------------------------------
    "aramaki.trigger_label" => {:string, "Label that opts an issue into the factory"},
    "aramaki.max_concurrent" => {:integer, "Missions Aramaki keeps in flight at once"},
    "aramaki.sentry_levels" => {:string_list, "Sentry levels admitted as missions"},

    # -- Intake routing ---------------------------------------------------
    "sentry_project_to_sector" => {:string_map, "Sentry project slug → sector id"},
    "jira_project_to_sector" => {:string_map, "Jira project key → sector id"},

    # -- Operational timing -----------------------------------------------
    "approvals.timeout_hours" => {:integer, "Hours before an approval auto-resolves"}
  }

  # Substrings that mark a key as secret-shaped whatever the allow-list says.
  @secret_patterns ~w(key secret token password credential auth api_key)

  @doc "Every settable key with its kind and description, for tool schemas and help."
  @spec all() :: %{key() => {atom(), String.t()}}
  def all, do: @settable

  @doc "Sorted list of settable keys."
  @spec keys() :: [key()]
  def keys, do: @settable |> Map.keys() |> Enum.sort()

  @doc """
  Validates a key/value pair for writing.

  Returns `{:ok, path, coerced}` where `path` is the atom list
  `GiTF.Config.Provider` uses, or `{:error, reason}`.
  """
  @spec validate(key(), term()) ::
          {:ok, [atom()], term()}
          | {:error, :not_settable | :secret_shaped | {:bad_value, atom()}}
  def validate(key, value) when is_binary(key) do
    cond do
      secret_shaped?(key) ->
        {:error, :secret_shaped}

      not Map.has_key?(@settable, key) ->
        {:error, :not_settable}

      true ->
        {kind, _desc} = Map.fetch!(@settable, key)

        case coerce(kind, value) do
          {:ok, coerced} -> {:ok, path_for(key), coerced}
          :error -> {:error, {:bad_value, kind}}
        end
    end
  end

  def validate(_, _), do: {:error, :not_settable}

  @doc """
  Whether a key looks like a secret regardless of the allow-list.

  Defence in depth: if someone adds an entry to `@settable` carelessly, this
  still refuses it. A key can only be written if it passes both.
  """
  @spec secret_shaped?(key()) :: boolean()
  def secret_shaped?(key) when is_binary(key) do
    down = String.downcase(key)
    Enum.any?(@secret_patterns, &String.contains?(down, &1))
  end

  def secret_shaped?(_), do: true

  defp path_for(key), do: key |> String.split(".") |> Enum.map(&String.to_atom/1)

  # -- Coercion ----------------------------------------------------------

  defp coerce(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp coerce(:boolean, "true"), do: {:ok, true}
  defp coerce(:boolean, "false"), do: {:ok, false}
  defp coerce(:boolean, _), do: :error

  defp coerce(:integer, v) when is_integer(v) and v >= 0, do: {:ok, v}

  defp coerce(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp coerce(:integer, _), do: :error

  defp coerce(:string, v) when is_binary(v) and v != "", do: {:ok, v}
  defp coerce(:string, _), do: :error

  defp coerce(:string_list, v) when is_list(v) do
    if Enum.all?(v, &is_binary/1), do: {:ok, v}, else: :error
  end

  defp coerce(:string_list, v) when is_binary(v) do
    case v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> :error
      list -> {:ok, list}
    end
  end

  defp coerce(:string_list, _), do: :error

  defp coerce(:string_map, v) when is_map(v) do
    if Enum.all?(v, fn {k, val} -> is_binary(k) and is_binary(val) end),
      do: {:ok, v},
      else: :error
  end

  defp coerce(:string_map, _), do: :error
end
