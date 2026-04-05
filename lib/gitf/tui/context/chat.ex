defmodule GiTF.TUI.Context.Chat do
  @moduledoc """
  Manages the chat history.
  """

  defstruct history: []

  @type content :: String.t() | {:questions, String.t(), [String.t()]}
  @type message :: %{
          role: :user | :assistant | :system,
          content: content(),
          timestamp: DateTime.t()
        }
  @type t :: %__MODULE__{
          history: list(message())
        }

  def new do
    %__MODULE__{}
  end

  def add_message(%__MODULE__{history: history} = state, role, content)
      when role in [:user, :assistant, :system] do
    message = %{role: role, content: content, timestamp: DateTime.utc_now()}
    %{state | history: history ++ [message]}
  end

  def clear(%__MODULE__{} = state) do
    %{state | history: []}
  end
end
