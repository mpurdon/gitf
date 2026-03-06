defmodule Hive.Plugin.ToolProvider do
  @moduledoc """
  Behaviour for tool provider plugins.

  Tool providers supply `ReqLLM.Tool` structs that get merged into
  the agent tool pipeline alongside static tools from `ToolBox`.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback tools() :: [ReqLLM.Tool.t()]
end
