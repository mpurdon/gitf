defmodule GiTF.Dashboard.Toastable do
  @moduledoc """
  Adds toast notification support to any dashboard LiveView.

  Usage:

      use GiTF.Dashboard.Toastable

  This:
  1. Injects `@toasts []` into initial assigns (call `init_toasts/1` in mount)
  2. Adds `handle_info` clauses for waggle → toast conversion and auto-dismiss
  3. Passes toasts to AppLayout automatically

  Pages must call `init_toasts(socket)` in their mount, and pass
  `toasts={@toasts}` to the AppLayout live_component.
  """

  defmacro __using__(_opts) do
    quote do
      import GiTF.Dashboard.Helpers, only: [push_toast: 3, handle_dismiss_toast: 2, maybe_toast_waggle: 2]

      defp init_toasts(socket) do
        Phoenix.Component.assign_new(socket, :toasts, fn -> [] end)
      end

      # Auto-convert notable waggle messages to toasts.
      # Pages that define their own {:waggle_received, _} handler can still
      # call `maybe_apply_toast(socket, waggle)` manually.
      defp maybe_apply_toast(socket, waggle) do
        case maybe_toast_waggle(socket, waggle) do
          {:toast, s} -> s
          :skip -> socket
        end
      end

      def handle_info({:dismiss_toast, toast_id}, socket) do
        {:noreply, handle_dismiss_toast(socket, toast_id)}
      end
    end
  end
end
