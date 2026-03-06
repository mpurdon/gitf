defmodule Hive.Plugin do
  @moduledoc """
  Plugin DSL macro. Use `use Hive.Plugin, type: :model` to declare a plugin.

  Automatically sets the behaviour module and provides helper functions
  for registration with the Plugin Manager.
  """

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    behaviour = behaviour_for(type)

    quote do
      @behaviour unquote(behaviour)

      @doc false
      def __plugin_type__, do: unquote(type)

      @doc false
      def __plugin_behaviour__, do: unquote(behaviour)

      defoverridable []
    end
  end

  @doc false
  def behaviour_for(:model), do: Hive.Plugin.Model
  def behaviour_for(:theme), do: Hive.Plugin.Theme
  def behaviour_for(:command), do: Hive.Plugin.Command
  def behaviour_for(:lsp), do: Hive.Plugin.LSP
  def behaviour_for(:mcp), do: Hive.Plugin.MCP
  def behaviour_for(:channel), do: Hive.Plugin.Channel
  def behaviour_for(:tool_provider), do: Hive.Plugin.ToolProvider
end
