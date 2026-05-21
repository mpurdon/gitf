defmodule GiTF.Knowledge.Ingest.URLTest do
  use GiTF.StoreCase

  alias GiTF.Knowledge.Ingest.URL, as: URLIngest
  alias GiTF.Knowledge.Page

  setup do
    gitf_root =
      Path.join(System.tmp_dir!(), "url-ingest-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(gitf_root, ".gitf"))
    File.write!(Path.join([gitf_root, ".gitf", "config.toml"]), "")

    prior_path = System.get_env("GITF_PATH")
    System.put_env("GITF_PATH", gitf_root)

    on_exit(fn ->
      if prior_path,
        do: System.put_env("GITF_PATH", prior_path),
        else: System.delete_env("GITF_PATH")

      File.rm_rf!(gitf_root)
    end)

    :ok
  end

  describe "slug_from_url/1" do
    test "host + path becomes host_path-segments" do
      assert URLIngest.slug_from_url("https://hex.pm/docs/usage") == "hex-pm_docs-usage"
    end

    test "strips .html and trailing slash" do
      assert URLIngest.slug_from_url("https://example.com/guide.html") == "example-com_guide"
      assert URLIngest.slug_from_url("https://example.com/foo/") == "example-com_foo"
    end

    test "bare host with no path returns just the host" do
      assert URLIngest.slug_from_url("https://example.com/") == "example-com"
    end

    test "falls back to url-ingest for unparseable urls" do
      assert URLIngest.slug_from_url("") == "url-ingest"
    end
  end

  describe "ingest/3 — HTML → markdown pipeline" do
    test "extracts title, converts headings + paragraphs, persists as a Page" do
      url = "https://example.test/intro"

      html = """
      <!doctype html>
      <html>
        <head><title>Intro Guide</title></head>
        <body>
          <main>
            <h1>Intro Guide</h1>
            <p>Welcome to the platform.</p>
            <h2>Getting started</h2>
            <p>Run <code>mix new my_app</code> to scaffold a project.</p>
            <ul>
              <li>Read the docs</li>
              <li>Run the tests</li>
            </ul>
          </main>
          <nav>menu</nav>
          <script>alert(1)</script>
        </body>
      </html>
      """

      stub_req(fn ^url, _opts -> {:ok, 200, html} end)

      result = URLIngest.ingest(url, "mysector", depth: 0)

      assert [{^url, "example-test_intro"}] = result.ingested
      assert result.errors == []

      page = Page.get("mysector", "example-test_intro")
      assert page.title == "Intro Guide"
      {:ok, body, _hash} = Page.read_body("mysector", page.slug)

      assert body =~ "Source: " <> url
      assert body =~ "# Getting started" or body =~ "## Getting started"
      assert body =~ "`mix new my_app`"
      assert body =~ "- Read the docs"
      refute body =~ "alert(1)"
      refute body =~ "menu"
    end

    test "skips depth: 1 when not requested (single page only)" do
      html = """
      <html><body>
        <h1>Page 1</h1>
        <a href="https://example.test/two">two</a>
      </body></html>
      """

      stub_req(fn _url, _opts -> {:ok, 200, html} end)

      result = URLIngest.ingest("https://example.test/one", "s", depth: 0)
      assert length(result.ingested) == 1
    end

    test "http error → result.errors entry, nothing persisted" do
      stub_req(fn _url, _opts -> {:ok, 404, "not found"} end)

      result = URLIngest.ingest("https://example.test/missing", "s")

      assert result.ingested == []
      assert [{"https://example.test/missing", {:http_status, 404}}] = result.errors
      assert Page.get("s", "example-test_missing") == nil
    end

    test "dry_run: true logs but does not persist" do
      html = "<html><body><h1>Dry</h1><p>Body</p></body></html>"
      stub_req(fn _url, _opts -> {:ok, 200, html} end)

      result = URLIngest.ingest("https://example.test/dry", "s", dry_run: true)

      assert [{_, "example-test_dry"}] = result.ingested
      # Dry run still reports "ingested" (parsed + slugged successfully)
      # but the Archive record must NOT exist.
      assert Page.get("s", "example-test_dry") == nil
    end
  end

  # -- Req stub via Req.Test  ------------------------------------------------
  #
  # Req has built-in test support via Req.Test, but for our purposes we
  # need a simpler shim: route Req.get calls through a per-test fn. We
  # achieve this by installing a Req.Test plug via Application env.

  defp stub_req(handler) do
    plug =
      Req.Test.expect(__MODULE__, fn conn ->
        url = "https://#{conn.host}#{conn.request_path}"

        case handler.(url, []) do
          {:ok, status, body} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.resp(status, body)
        end
      end)

    Application.put_env(:req, :default_options, plug: {Req.Test, __MODULE__})
    on_exit_cleanup_req()
    plug
  end

  defp on_exit_cleanup_req do
    on_exit(fn -> Application.delete_env(:req, :default_options) end)
  end
end
