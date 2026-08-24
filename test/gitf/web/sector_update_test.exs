defmodule GiTF.Web.SectorUpdateTest do
  use GiTF.StoreCase

  import Phoenix.ConnTest

  alias GiTF.Web.ApiController

  defp put_sector(id, body) do
    conn =
      build_conn(:put, "/api/v1/sectors/#{id}", body)
      |> Map.put(:body_params, body)

    ApiController.update_sector(conn, Map.put(body, "id", id))
  end

  setup do
    {:ok, sector} = GiTF.Archive.put(:sectors, %{id: "sec-test1", name: "t", path: "/tmp/t"})
    %{sector: sector}
  end

  test "sets validation_command", %{sector: sector} do
    conn = put_sector(sector.id, %{"validation_command" => "npm test"})
    assert conn.status in [nil, 200]
    assert %{validation_command: "npm test"} = GiTF.Archive.get(:sectors, sector.id)
  end

  test "rejects an invalid sync_strategy", %{sector: sector} do
    conn = put_sector(sector.id, %{"sync_strategy" => "yolo"})
    assert conn.status == 422
  end

  test "rejects empty updates", %{sector: sector} do
    conn = put_sector(sector.id, %{})
    assert conn.status == 422
  end

  # Without the whitelist entry the API 422s on the key, so the operator escape
  # hatch for a sector that can't validate in 120s would be unreachable.
  test "sets validation_timeout_ms", %{sector: sector} do
    conn = put_sector(sector.id, %{"validation_timeout_ms" => 1_800_000})
    assert conn.status in [nil, 200]
    assert %{validation_timeout_ms: 1_800_000} = GiTF.Archive.get(:sectors, sector.id)
  end

  test "clears validation_timeout_ms back to the derived budget", %{sector: sector} do
    put_sector(sector.id, %{"validation_timeout_ms" => 600_000})
    conn = put_sector(sector.id, %{"validation_timeout_ms" => nil})

    assert conn.status in [nil, 200]
    assert %{validation_timeout_ms: nil} = GiTF.Archive.get(:sectors, sector.id)
  end

  test "rejects a non-positive or non-numeric validation_timeout_ms", %{sector: sector} do
    for bad <- [0, -1, "600000", 1.5] do
      assert put_sector(sector.id, %{"validation_timeout_ms" => bad}).status == 422,
             "expected 422 for #{inspect(bad)}"
    end

    refute Map.get(GiTF.Archive.get(:sectors, sector.id), :validation_timeout_ms)
  end

  test "serializes validation_timeout_ms so the remote CLI can see it", %{sector: sector} do
    conn = put_sector(sector.id, %{"validation_timeout_ms" => 900_000})

    assert %{"data" => %{"validation_timeout_ms" => 900_000}} = Jason.decode!(conn.resp_body)
  end

  test "404 for unknown sector" do
    conn = put_sector("sec-nope", %{"validation_command" => "true"})
    assert conn.status == 404
  end
end
