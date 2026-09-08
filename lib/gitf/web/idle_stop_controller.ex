defmodule GiTF.Web.IdleStopController do
  @moduledoc """
  The Catwalk's "keep the box awake" button.

  `POST /dashboard/idle-stop/hold` with `minutes` sets a bounded
  `GiTF.IdleStop` override so the box stays up for at least that long
  from now, whatever the idle countdown already says. Tailnet identity is
  the actor; the override still expires on its own — this is the same
  guard the MCP tool has, reached from the page's sleep banner.
  """

  use Phoenix.Controller, formats: [:json]

  @min_minutes 5
  @max_minutes 12 * 60

  def hold(conn, params) do
    minutes = params |> Map.get("minutes", "60") |> to_string() |> Integer.parse()

    with {minutes, _} when minutes >= @min_minutes and minutes <= @max_minutes <- minutes,
         {:ok, override} <-
           GiTF.IdleStop.set(idle_minutes_for(minutes), minutes, reason: reason(conn)) do
      GiTF.AuditLog.record(actor(conn), "idle_stop.hold", "factory", %{minutes: minutes})
      json(conn, %{data: %{until: override.expires_at, idle_minutes: override.idle_minutes}})
    else
      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})

      _ ->
        conn
        |> put_status(422)
        |> json(%{error: "minutes must be #{@min_minutes}-#{@max_minutes}"})
    end
  end

  # The countdown runs from idle_since, which is in the past; to guarantee
  # `minutes` from NOW the threshold must cover what has already elapsed.
  defp idle_minutes_for(minutes) do
    elapsed =
      DateTime.diff(DateTime.utc_now(), GiTF.Observability.Activity.last_activity_at(), :minute)

    min(max(elapsed, 0) + minutes, @max_minutes)
  end

  defp actor(conn) do
    case conn.assigns[:tailnet_identity] do
      %{login: login} when is_binary(login) -> login
      _ -> "dashboard"
    end
  end

  defp reason(conn), do: "held from the Catwalk by #{actor(conn)}"
end
