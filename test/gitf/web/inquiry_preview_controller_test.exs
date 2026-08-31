defmodule GiTF.Web.InquiryPreviewControllerTest do
  @moduledoc """
  Serving a mockup image, and the two things about it that are security
  decisions rather than plumbing.

  **It is a controller and not a static mount.** `Plug.Static` sits above
  the router in `GiTF.Web.Endpoint`, so nothing it serves ever reaches a
  pipeline and `GiTF.Web.TailnetAuth` never runs for it. Mounting the
  screenshots directory would have published every unreleased design
  decision to whoever can reach the port — `0.0.0.0` in the container.

  **A request cannot name a file.** The `option_id` in the path is only
  ever compared for equality against the options the store already holds;
  the filesystem path comes off the record, and `Preview.read/2` re-checks
  it is inside the screenshots root before reading. There is no way to
  express a path in the request at all.

  A 404 here is a normal outcome, not a fault: previews are pruned on age
  and on a disk budget, and an answered inquiry outlives its images by
  design.
  """
  use GiTF.StoreCase

  import Phoenix.ConnTest, except: [get: 2, get: 3]

  alias GiTF.Archive
  alias GiTF.Web.InquiryPreviewController

  setup do
    root = Path.join(System.tmp_dir!(), "gitf_ctl_prev_#{:erlang.unique_integer([:positive])}")
    previous = Application.get_env(:gitf, :visual_screenshots_root)
    Application.put_env(:gitf, :visual_screenshots_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gitf, :visual_screenshots_root, previous),
        else: Application.delete_env(:gitf, :visual_screenshots_root)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp inquiry!(options) do
    {:ok, record} =
      Archive.insert(:inquiries, %{
        mission_id: "msn-1",
        key: "icons",
        phase: "design",
        kind: :choice,
        prompt: "Which priority indicator?",
        options: options,
        status: "open",
        asked_at: DateTime.utc_now()
      })

    record
  end

  defp write_png!(root, name) do
    path = Path.join([root, "inquiries", "msn-1", "icons", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "PNG-BYTES")
    path
  end

  defp fetch(id, option_id) do
    InquiryPreviewController.show(
      build_conn(:get, "/dashboard/questions/#{id}/preview/#{option_id}"),
      %{"id" => id, "option_id" => option_id}
    )
  end

  test "serves the image recorded on the option", %{root: root} do
    png = write_png!(root, "bars.png")
    record = inquiry!([%{id: "bars", label: "Bars", preview: %{png: png}}])

    conn = fetch(record.id, "bars")

    assert conn.status == 200
    assert conn.resp_body == "PNG-BYTES"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
  end

  test "the image is cached — a LiveView heartbeat must not re-fetch every mockup", %{root: root} do
    png = write_png!(root, "bars.png")
    record = inquiry!([%{id: "bars", label: "Bars", preview: %{png: png}}])

    assert ["private, max-age=3600"] =
             Plug.Conn.get_resp_header(fetch(record.id, "bars"), "cache-control")
  end

  test "a pruned image is a plain 404, not a crash", %{root: root} do
    png = write_png!(root, "bars.png")
    record = inquiry!([%{id: "bars", label: "Bars", preview: %{png: png}}])
    File.rm!(png)

    conn = fetch(record.id, "bars")

    assert conn.status == 404
    assert conn.resp_body =~ "No preview"
  end

  test "an option that never had a preview is a 404" do
    record = inquiry!([%{id: "dots", label: "Dots", preview: nil}])

    assert fetch(record.id, "dots").status == 404
  end

  test "an unknown option id is a 404" do
    record = inquiry!([%{id: "bars", label: "Bars", preview: nil}])

    assert fetch(record.id, "nope").status == 404
  end

  test "an unknown inquiry is a 404" do
    assert fetch("inq-nope", "bars").status == 404
  end

  test "a traversal in the option id names nothing — the path is never built from the request" do
    record = inquiry!([%{id: "bars", label: "Bars", preview: nil}])

    assert fetch(record.id, "..%2F..%2Fetc%2Fpasswd").status == 404
  end

  test "a recorded path OUTSIDE the screenshots root is refused even though it exists" do
    # Belt to the braces: the request cannot express a path, but a record
    # written before a root change (or by a future caller) still must not
    # be able to serve an arbitrary file.
    outside =
      Path.join(System.tmp_dir!(), "gitf_outside_#{:erlang.unique_integer([:positive])}.png")

    File.write!(outside, "SECRET")
    on_exit(fn -> File.rm(outside) end)

    record = inquiry!([%{id: "bars", label: "Bars", preview: %{png: outside}}])

    conn = fetch(record.id, "bars")

    assert conn.status == 404
    refute conn.resp_body =~ "SECRET"
  end

  test "the route is inside the auth'd dashboard scope, not a static mount" do
    # A static mount would sit above the router and skip TailnetAuth
    # entirely — the whole reason this is a controller.
    assert %{plug: GiTF.Web.InquiryPreviewController, plug_opts: :show} =
             Phoenix.Router.route_info(
               GiTF.Web.Router,
               "GET",
               "/dashboard/questions/inq-1/preview/bars",
               "localhost"
             )

    assert Enum.member?(
             Phoenix.Router.route_info(
               GiTF.Web.Router,
               "GET",
               "/dashboard/questions/inq-1/preview/bars",
               "localhost"
             ).pipe_through,
             :dashboard_image
           )
  end
end
