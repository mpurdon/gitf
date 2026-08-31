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
        Archive.insert(@collection, %{
          slug: slug,
          name: attrs[:name] || attrs["name"] || slug,
          url: attrs[:url] || attrs["url"],
          instance_id: attrs[:instance_id] || attrs["instance_id"],
          webhook_secret_env: attrs[:webhook_secret_env] || attrs["webhook_secret_env"],
          api_key_env: attrs[:api_key_env] || attrs["api_key_env"],
          cost_cap_usd: attrs[:cost_cap_usd] || attrs["cost_cap_usd"],
          rules: attrs[:rules] || attrs["rules"],
          mode: attrs[:mode] || attrs["mode"] || "normal",
          inserted_at: DateTime.utc_now()
        })
    end
  end

  def update(id, fun) when is_function(fun, 1), do: Archive.update(@collection, id, fun)

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

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,40}$/, slug)
end
