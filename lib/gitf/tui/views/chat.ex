defmodule GiTF.TUI.Views.Chat do
  @moduledoc """
  Renders the chat history with auto-scroll.
  """
  import Ratatouille.View
  alias GiTF.TUI.Constants

  def render(model) do
    %{chat: %{history: history}, chat_scroll: scroll} = model

    panel title: "Chat", height: :fill do
      viewport offset_y: scroll do
        for msg <- history do
          render_message(msg)
        end
      end
    end
  end

  defp render_message(%{role: _role, content: {:questions, preamble, questions}}) do
    [
      label(content: "Assistant: #{preamble}", color: Constants.color_assistant(), wrap: true),
      label(content: ""),
      for {q, i} <- Enum.with_index(questions, 1) do
        label do
          text(content: "  #{i}. ", color: :cyan)
          text(content: q, color: :white)
        end
      end,
      label(content: "")
    ]
  end

  defp render_message(%{role: role, content: content}) when is_binary(content) do
    color =
      case role do
        :user -> Constants.color_user()
        :assistant -> Constants.color_assistant()
        :system -> Constants.color_system()
      end

    prefix =
      case role do
        :user -> "User: "
        :assistant -> "Assistant: "
        :system -> "[System] "
      end

    label(content: prefix <> content, color: color, wrap: true)
  end
end
