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
         {:ok, override, outcome} <- GiTF.IdleStop.hold(minutes, reason: reason(conn)) do
      # The outcome goes in the record: a tap that found a longer hold
      # already in place changed nothing, and the audit log used to say it
      # had set one.
      GiTF.AuditLog.record(actor(conn), "idle_stop.hold", "factory", %{
        minutes: minutes,
        outcome: outcome,
        until: override.expires_at
      })

      json(conn, %{
        data: %{
          outcome: outcome,
          until: override.expires_at,
          idle_minutes: override.idle_minutes
        }
      })
    else
      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})

      _ ->
        conn
        |> put_status(422)
        |> json(%{error: "minutes must be #{@min_minutes}-#{@max_minutes}"})
    end
  end

  @doc """
  Gives a hold back: the configured idle threshold applies again at once.

  The only way to undo a hold used to be the MCP. Someone who held the box
  four hours from the Catwalk and then finished early had two choices —
  find an MCP client, or press "Sleep now" in Discord, which stops the
  instance outright rather than letting it idle down on its own terms.
  """
  def release(conn, _params) do
    held = GiTF.IdleStop.active()
    :ok = GiTF.IdleStop.clear()

    GiTF.AuditLog.record(actor(conn), "idle_stop.release", "factory", %{
      had_hold: held != nil,
      until: held && held.expires_at
    })

    json(conn, %{data: %{released: held != nil}})
  end

  defp actor(conn) do
    case conn.assigns[:tailnet_identity] do
      %{login: login} when is_binary(login) -> login
      _ -> "dashboard"
    end
  end

  defp reason(conn), do: "held from the Catwalk by #{actor(conn)}"
end
