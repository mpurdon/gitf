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

  test "404 for unknown sector" do
    conn = put_sector("sec-nope", %{"validation_command" => "true"})
    assert conn.status == 404
  end
end
