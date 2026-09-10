defmodule GiTF.Observability.AlertDataTest do
  @moduledoc """
  Alerts that a phone can act on carry their facts as `data`, not only as
  prose — a question's id and options, an approval's mission. Without them
  a channel can show the question but never offer the answer.
  """
  use GiTF.StoreCase

  setup do
    handler = "alert-data-#{:erlang.unique_integer([:positive])}"
    pid = self()

    :telemetry.attach(
      handler,
      [:gitf, :alert, :raised],
      fn _e, _m, meta, _c -> send(pid, {:alert, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "a question announces itself with its id, kind and options" do
    {:ok, m} =
      GiTF.Archive.insert(:missions, %{
        name: "q",
        goal: "g",
        status: "active",
        sector_id: "s",
        current_phase: "awaiting_input",
        input_return_phase: "design",
        artifacts: %{},
        ops: []
      })

    {:ok, inquiry, :asked} =
      GiTF.Inquiry.ask(m.id, %{
        key: "layout",
        phase: "design",
        kind: :choice,
        prompt: "Which layout?",
        options: [%{id: "grid", label: "Grid", rationale: "dense"}, %{id: "list", label: "List"}]
      })

    assert_receive {:alert, %{type: :input_requested, data: data}}
    assert data.inquiry_id == inquiry.id
    assert data.mission_id == m.id
    assert data.kind == :choice
    assert [%{id: "grid", label: "Grid", rationale: "dense"}, %{id: "list"}] = data.options
  end

  test "an alert raised without data carries an empty map, never nil" do
    GiTF.Observability.Alerts.dispatch_webhook(:sync_retry, "again #{System.unique_integer()}")
    assert_receive {:alert, %{type: :sync_retry, data: %{}}}
  end
end
