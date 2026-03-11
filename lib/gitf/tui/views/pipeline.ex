defmodule GiTF.TUI.Views.Pipeline do
  @moduledoc "Renders the pipeline stages view for all ops."
  import Ratatouille.View

  def render(model) do
    ops = model[:ops] || []
    sync_queue = model[:sync_queue] || %{pending: [], active: nil, completed: []}

    visible =
      ops
      |> Enum.reject(&(&1[:status] == "done" && &1[:merged_at]))
      |> Enum.sort_by(&(&1[:status] || ""), :asc)
      |> then(fn js ->
        active = Enum.reject(js, &(&1[:status] == "done"))
        done = Enum.filter(js, &(&1[:status] == "done")) |> Enum.take(5)
        active ++ done
      end)

    panel title: "Pipeline [F2]", height: :fill do
      if Enum.empty?(visible) do
        label(content: "No ops in pipeline", color: :white)
      else
        # Header
        [
          label do
            text(content: String.pad_trailing("Job", 28), color: :white, attributes: [:bold])
            text(content: "Sc ", color: :white, attributes: [:bold])
            text(content: "Tr ", color: :white, attributes: [:bold])
            text(content: "Be ", color: :white, attributes: [:bold])
            text(content: "Dr ", color: :white, attributes: [:bold])
            text(content: "Mg", color: :white, attributes: [:bold])
          end
        ] ++
          Enum.map(visible, fn op ->
            {sc, tr, be, dr, mg} = stages(op, sync_queue)
            title = String.slice(op[:title] || "untitled", 0, 26) |> String.pad_trailing(27)

            label do
              text(content: title <> " ", color: :white)
              stage_text(sc)
              text(content: " ")
              stage_text(tr)
              text(content: " ")
              stage_text(be)
              text(content: " ")
              stage_text(dr)
              text(content: " ")
              stage_text(mg)
            end
          end)
      end
    end
  end

  defp stage_text(:done), do: text(content: "ok", color: :green)
  defp stage_text(:active), do: text(content: ">>", color: :blue, attributes: [:bold])
  defp stage_text(:pending), do: text(content: "..", color: :yellow)
  defp stage_text(:failed), do: text(content: "XX", color: :red, attributes: [:bold])
  defp stage_text(:skip), do: text(content: "--", color: :white)
  defp stage_text(_), do: text(content: "--", color: :white)

  defp stages(op, mq) do
    recon =
      cond do
        op[:skip_scout] == true -> :skip
        op[:scout_findings] != nil -> :done
        true -> :skip
      end

    triage = if op[:complexity], do: :done, else: :skip

    ghost =
      case op[:status] do
        "running" -> :active
        "done" -> :done
        "failed" -> :failed
        "assigned" -> :pending
        _ -> :pending
      end

    tachikoma =
      cond do
        op[:skip_verification] == true -> :skip
        op[:verification_status] == "passed" -> :done
        op[:verification_status] == "failed" -> :failed
        op[:verification_status] == "pending" -> :pending
        op[:status] in ["done", "failed"] && !op[:skip_verification] -> :pending
        true -> :skip
      end

    sync =
      cond do
        op[:merged_at] != nil -> :done
        in_active?(mq, op[:id]) -> :active
        in_pending?(mq, op[:id]) -> :pending
        in_completed?(mq, op[:id]) -> :done
        ghost == :done && tachikoma in [:done, :skip] -> :pending
        true -> :skip
      end

    {recon, triage, ghost, tachikoma, sync}
  end

  defp in_active?(%{active: nil}, _), do: false
  defp in_active?(%{active: a}, id), do: (a[:op_id] || a.op_id) == id
  defp in_active?(_, _), do: false

  defp in_pending?(%{pending: p}, id), do: Enum.any?(p, fn {jid, _} -> jid == id end)
  defp in_pending?(_, _), do: false

  defp in_completed?(%{completed: c}, id), do: Enum.any?(c, fn {jid, _, _} -> jid == id end)
  defp in_completed?(_, _), do: false
end
