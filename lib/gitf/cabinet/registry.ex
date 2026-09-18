defmodule GiTF.Cabinet.Registry do
  @moduledoc """
  The ministry registry — one record per client Section.

  Secrets are held by REFERENCE only: `webhook_secret_env` and
  `api_key_env` name environment variables (loaded from
  `/etc/gitf/cabinet.env` on the box), never values. The Cabinet must
  stay a thing whose store can leak without leaking a ministry.
  """

  alias GiTF.Archive

  @collection :ministries
  @modes ~w(normal vacation off)

  @doc "Every ministry, stable order by slug."
  def list, do: @collection |> Archive.all() |> Enum.sort_by(& &1.slug)

  def get(id), do: Archive.get(@collection, id)

  def by_slug(slug) when is_binary(slug) do
    Archive.find_one(@collection, &(&1.slug == slug))
  end

  @doc """
  Resolves prose to a ministry: `"home affairs"` → the `home-affairs` record.

  Every other lookup in the codebase is exact-slug, which is right for a
  webhook path and wrong for a person typing a sentence. Tried in order,
  stopping at the first that matches exactly one ministry:

    1. the slug, verbatim
    2. the display name, case-insensitively
    3. slug-ified input — trimmed, lowercased, runs of spaces/underscores
       collapsed to a single hyphen
    4. `String.jaro_distance/2` against both slug and name, best score
       above `@fuzzy_floor`

  Returns `{:ok, ministry}`, or `{:ambiguous, [ministry]}` when more than
  one is equally plausible, or `{:error, :no_match}`. Ambiguity is
  returned rather than broken by a coin flip so the caller can ask —
  picking a ministry for someone is how you wake the wrong box.
  """
  @spec resolve(term()) ::
          {:ok, map()} | {:ambiguous, [map()]} | {:error, :no_match}
  def resolve(input) when is_binary(input) do
    trimmed = String.trim(input)

    if trimmed == "" do
      {:error, :no_match}
    else
      ministries = list()
      down = String.downcase(trimmed)

      exact_slug(ministries, trimmed) ||
        exact_name(ministries, down) ||
        exact_slug(ministries, slugify(down)) ||
        fuzzy(ministries, down) ||
        {:error, :no_match}
    end
  end

  def resolve(_), do: {:error, :no_match}

  # Below this, a "match" is a guess. 0.85 keeps "home-affars" (0.94) and
  # loses "trajector" against "home affairs" (0.46).
  @fuzzy_floor 0.85

  defp exact_slug(ministries, candidate) do
    case Enum.find(ministries, &(&1.slug == candidate)) do
      nil -> nil
      m -> {:ok, m}
    end
  end

  defp exact_name(ministries, down) do
    ministries
    |> Enum.filter(&(String.downcase(&1[:name] || "") == down))
    |> one_or_ambiguous()
  end

  defp fuzzy(ministries, down) do
    scored =
      ministries
      |> Enum.map(&{&1, score(&1, down)})
      |> Enum.filter(fn {_m, s} -> s >= @fuzzy_floor end)

    case scored do
      [] ->
        nil

      _ ->
        best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()

        scored
        |> Enum.filter(fn {_m, s} -> s == best end)
        |> Enum.map(&elem(&1, 0))
        |> one_or_ambiguous()
    end
  end

  # The best of slug-vs-input and name-vs-input: a ministry may be typed
  # either way, and losing on one spelling should not sink the other.
  defp score(ministry, down) do
    slugged = slugify(down)

    max(
      String.jaro_distance(ministry.slug, slugged),
      String.jaro_distance(String.downcase(ministry[:name] || ""), down)
    )
  end

  defp one_or_ambiguous([]), do: nil
  defp one_or_ambiguous([one]), do: {:ok, one}
  defp one_or_ambiguous(many), do: {:ambiguous, many}

  defp slugify(str) do
    str
    |> String.replace(~r/[\s_]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Registers a ministry. Requires `slug` (path-safe, unique), `name`, and
  `url` (the Section's base URL). Optional: `instance_id`,
  `webhook_secret_env`, `api_key_env`, `cost_cap_usd`, `rules` (a JDM
  document; nil = the default ruleset), `mode` (default "normal").
  """
  def create(attrs) when is_map(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    cond do
      not valid_slug?(slug) ->
        {:error, {:invalid, "slug must be lowercase letters, digits and dashes"}}

      by_slug(slug) != nil ->
        {:error, {:invalid, "slug #{slug} is taken"}}

      true ->
        result =
          Archive.insert(@collection, %{
            slug: slug,
            name: attrs[:name] || attrs["name"] || slug,
            url: attrs[:url] || attrs["url"],
            instance_id: attrs[:instance_id] || attrs["instance_id"],
            webhook_secret_env: attrs[:webhook_secret_env] || attrs["webhook_secret_env"],
            api_key_env: attrs[:api_key_env] || attrs["api_key_env"],
            cost_cap_usd: normalize_cap(attrs[:cost_cap_usd] || attrs["cost_cap_usd"]),
            rules: attrs[:rules] || attrs["rules"],
            mode: attrs[:mode] || attrs["mode"] || "normal",
            inserted_at: DateTime.utc_now()
          })

        # A ministry gets its Discord channel the moment it exists.
        with {:ok, ministry} <- result, true <- discord_bot_up?() do
          GiTF.Cabinet.Discord.Bot.ministry_registered(ministry)
        end

        result
    end
  end

  defp discord_bot_up?, do: Process.whereis(GiTF.Cabinet.Discord.Bot) != nil

  def update(id, fun) when is_function(fun, 1), do: Archive.update(@collection, id, fun)

  @editable ~w(name url instance_id webhook_secret_env api_key_env cost_cap_usd)

  @doc """
  Operator edit from the Console: only the editable fields, cost cap
  parsed as a number, empty strings meaning "clear". The slug is
  identity and never edited — retire and re-register instead.
  """
  def edit(id, attrs) when is_map(attrs) do
    fields =
      for key <- @editable,
          {:ok, raw} <- [Map.fetch(attrs, key)],
          into: %{} do
        {String.to_existing_atom(key), normalize_field(key, raw)}
      end

    case fields[:cost_cap_usd] do
      {:error, bad} -> {:error, {:invalid, "cost cap #{inspect(bad)} is not a number"}}
      _ -> update(id, &Map.merge(&1, fields))
    end
  end

  defp normalize_field("cost_cap_usd", raw) do
    case raw |> to_string() |> String.trim() do
      "" ->
        nil

      str ->
        case Float.parse(str) do
          {n, ""} -> n
          _ -> {:error, str}
        end
    end
  end

  defp normalize_field(_key, raw) do
    case raw |> to_string() |> String.trim() do
      "" -> nil
      str -> str
    end
  end

  def delete(id), do: Archive.delete(@collection, id)

  @doc "Sets the ministry's mode; unknown modes are refused."
  def set_mode(id, mode) when mode in @modes do
    update(id, &Map.put(&1, :mode, mode))
  end

  def set_mode(_id, mode), do: {:error, {:invalid, "unknown mode #{inspect(mode)}"}}

  @doc "The ministry's webhook secret, resolved from its env reference."
  def webhook_secret(%{webhook_secret_env: env}) when is_binary(env) and env != "" do
    case System.get_env(env) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  def webhook_secret(_), do: nil

  defp normalize_cap(nil), do: nil
  defp normalize_cap(n) when is_number(n), do: n / 1

  defp normalize_cap(str) when is_binary(str) do
    case normalize_field("cost_cap_usd", str) do
      {:error, _} -> nil
      v -> v
    end
  end

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,40}$/, slug)
end
