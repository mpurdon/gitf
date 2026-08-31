defmodule GiTF.Web.InquiryPreviewController do
  @moduledoc """
  Serves the rendered mockup for one option of one question.

  ## Why a controller and not a static directory

  Mounting `.gitf/screenshots` under `Plug.Static` would have been one
  line, and it would have been a hole. `Plug.Static` and
  `GiTF.Web.StaticAssets` sit at `GiTF.Web.Endpoint` lines 25 and 27 —
  ABOVE `plug(GiTF.Web.Router)` — so nothing served that way ever reaches
  a router pipeline, and `GiTF.Web.TailnetAuth` lives in the pipelines.
  Anything mounted statically is readable by whoever can reach the port,
  which in the container is `0.0.0.0`. A mockup is a picture of an
  unreleased product decision; it belongs behind the same 403 as the
  mission it was drawn for.

  So this follows `GiTF.Web.DeckController`: a plain GET inside the
  `:dashboard` pipeline, which is the established shape for "a response
  the browser fetches directly but that still needs an identity".

  ## Why the request cannot name a file

  The `option_id` in the path is only ever compared for EQUALITY against
  the options the store already holds; the filesystem path comes off the
  inquiry record. `GiTF.Inquiry.Preview.read/2` then re-checks that the
  recorded path is inside the screenshots root before reading it. A
  request therefore has no way to express a path at all, traversal or
  otherwise, and a record written by some future caller still cannot
  serve a file from outside the one directory a headless browser is
  allowed to write into.

  ## 404 is a normal outcome

  Previews are pruned on age and on a disk budget
  (`GiTF.Inquiry.Preview.prune/0`), and an answered inquiry outlives its
  images by design. A card whose picture is gone is not broken — the
  `<img>` in `GiTF.Dashboard.InquiryCard` folds itself away on error and
  the option's label and rationale stay exactly where they were. This
  endpoint's job on a missing file is to say so quickly and cheaply, not
  to reconstruct anything.
  """

  use Phoenix.Controller, formats: [:html]

  alias GiTF.Inquiry
  alias GiTF.Inquiry.Preview

  def show(conn, %{"id" => id, "option_id" => option_id}) do
    with %{} = inquiry <- Inquiry.get(id),
         {:ok, png} <- Preview.read(inquiry, option_id) do
      conn
      # No charset: this is a binary, and `image/png; charset=utf-8` is a
      # content type that describes nothing true about the response.
      |> put_resp_content_type("image/png", nil)
      # Immutable in practice: a preview's path is deterministic in
      # {mission, question key, option}, and the answer that was given
      # against it cannot change. The browser re-fetching a mockup on
      # every LiveView heartbeat would be the questions queue paying for
      # the same image all day.
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, png)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "No preview for that option.\n")
    end
  end
end
