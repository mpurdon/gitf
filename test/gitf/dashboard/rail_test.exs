defmodule GiTF.Dashboard.RailTest do
  @moduledoc """
  The rail is the operator's only persistent orientation, and it was wrong
  exactly when they were deepest in the app: every page that assigned a
  `/dashboard`-prefixed `current_path` matched none of `@concept_paths` and
  fell through to `:overview`. This holds every page's assigned path against
  the matcher so the two cannot drift apart again.
  """
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.AppLayout

  @expected %{
    "/" => :overview,
    "/progress" => :overview,
    "/costs" => :overview,
    "/missions" => :operations,
    "/missions/msn-abc123" => :operations,
    "/missions/msn-abc123/plan" => :operations,
    "/missions/new" => :operations,
    "/ops/op-abc123" => :operations,
    "/approvals" => :operations,
    "/questions" => :operations,
    "/merges" => :operations,
    "/ghosts" => :operations,
    "/shells" => :operations,
    "/links" => :operations,
    "/health" => :systems,
    "/providers" => :systems,
    "/models" => :systems,
    "/sectors" => :resources,
    "/rollback" => :resources,
    "/timeline" => :investigations,
    "/timeline/msn-abc123" => :investigations,
    "/workflows" => :automation,
    "/autonomy" => :automation,
    "/studio" => :automation,
    "/settings" => :administration
  }

  test "every path resolves to the concept it belongs to" do
    for {path, concept} <- @expected do
      assert AppLayout.concept_for(path) == concept,
             "#{path} resolved to #{inspect(AppLayout.concept_for(path))}, expected #{inspect(concept)}"
    end
  end

  test "every current_path a LiveView assigns is one the matcher knows" do
    assigned =
      Path.wildcard("lib/gitf/dashboard/live/*.ex")
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/assign\(:current_path, "([^"]+)"\)/, File.read!(file))
        |> Enum.map(fn [_, path] -> {Path.basename(file), path} end)
      end)

    assert assigned != [], "no current_path assignments found — did the layout change?"

    for {file, path} <- assigned do
      refute String.starts_with?(path, "/dashboard"),
             "#{file} assigns #{path}; the matcher works on unprefixed paths"

      # Settings must not silently resolve to Overview, and neither must anything else.
      if path != "/" do
        assert AppLayout.concept_for(path) != :overview or path in ["/progress", "/costs"],
               "#{file} assigns #{path}, which falls through to :overview"
      end
    end
  end
end
