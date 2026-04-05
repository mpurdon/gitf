defmodule GiTF.TUI.Context.Input do
  @moduledoc """
  Manages the input state, including text buffer, cursor position, and input history.
  """

  defstruct text: "", cursor: 0, history: [], history_index: nil

  @type t :: %__MODULE__{
          text: String.t(),
          cursor: non_neg_integer(),
          history: list(String.t()),
          history_index: non_neg_integer() | nil
        }

  def new do
    %__MODULE__{}
  end

  def insert_char(%__MODULE__{text: text, cursor: cursor} = state, char) when is_binary(char) do
    new_text =
      String.slice(text, 0, cursor) <> char <> String.slice(text, cursor, String.length(text))

    %{state | text: new_text, cursor: cursor + String.length(char)}
  end

  def delete_char(%__MODULE__{text: text, cursor: cursor} = state) when cursor > 0 do
    new_text =
      String.slice(text, 0, cursor - 1) <> String.slice(text, cursor, String.length(text))

    %{state | text: new_text, cursor: cursor - 1}
  end

  def delete_char(state), do: state

  def delete_char_forward(%__MODULE__{text: text, cursor: cursor} = state) do
    if cursor < String.length(text) do
      new_text =
        String.slice(text, 0, cursor) <> String.slice(text, cursor + 1, String.length(text))

      %{state | text: new_text}
    else
      state
    end
  end

  def move_cursor(%__MODULE__{cursor: cursor} = state, :left) when cursor > 0 do
    %{state | cursor: cursor - 1}
  end

  def move_cursor(%__MODULE__{text: text, cursor: cursor} = state, :right) do
    if cursor < String.length(text) do
      %{state | cursor: cursor + 1}
    else
      state
    end
  end

  def move_cursor(state, _), do: state

  def submit(%__MODULE__{text: text, history: history} = state) do
    new_history = if String.trim(text) != "", do: [text | history], else: history
    {%{state | text: "", cursor: 0, history: new_history, history_index: nil}, text}
  end

  def prev_history(%__MODULE__{history: []} = state), do: state

  def prev_history(%__MODULE__{history: history, history_index: nil} = state) do
    text = Enum.at(history, 0) || ""
    %{state | history_index: 0, text: text, cursor: String.length(text)}
  end

  def prev_history(%__MODULE__{history: history, history_index: index} = state) do
    if index + 1 < length(history) do
      new_index = index + 1
      text = Enum.at(history, new_index) || ""
      %{state | history_index: new_index, text: text, cursor: String.length(text)}
    else
      state
    end
  end

  def next_history(%__MODULE__{history_index: nil} = state), do: state

  def next_history(%__MODULE__{history_index: 0} = state) do
    %{state | history_index: nil, text: "", cursor: 0}
  end

  def next_history(%__MODULE__{history: history, history_index: index} = state) do
    new_index = index - 1
    text = Enum.at(history, new_index) || ""
    %{state | history_index: new_index, text: text, cursor: String.length(text)}
  end
end
