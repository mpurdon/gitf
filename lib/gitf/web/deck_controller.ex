defmodule GiTF.Web.DeckController do
  @moduledoc """
  Serves a mission's design decision as a downloadable, self-contained page.

  Sent as an attachment rather than rendered inline: the point of the deck is
  that it leaves the tailnet. A file can be attached to a message and opened
  by someone who will never reach this dashboard; a link cannot.
  """

  use Phoenix.Controller, formats: [:html]

  alias GiTF.Major.DesignDeck

  def show(conn, %{"id" => mission_id}) do
    case DesignDeck.render(mission_id) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{DesignDeck.filename(mission_id)}")
        )
        |> send_resp(200, html)

      {:error, :nothing_to_show} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "This mission has no design artifacts to build a deck from.")

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "Mission not found.")
    end
  end
end
