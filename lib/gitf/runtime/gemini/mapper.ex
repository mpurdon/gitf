defmodule GiTF.Runtime.Gemini.Mapper do
  @moduledoc """
  Maps ReqLLM structures to Google Gemini API formats.
  """

  @doc """
  Converts a list of ReqLLM.Tool structs to Gemini tool declarations.
  """
  def map_tools(tools) when is_list(tools) do
    function_declarations = Enum.map(tools, &map_tool/1)

    # Gemini expects %{"function_declarations" => [...]} inside a "tools" list
    [%{"function_declarations" => function_declarations}]
  end

  def map_tools(_), do: nil

  defp map_tool(%ReqLLM.Tool{name: name, description: description, parameter_schema: schema}) do
    %{
      "name" => name,
      "description" => description,
      "parameters" => map_parameters(schema)
    }
  end

  defp map_parameters(schema) when is_list(schema) do
    # ReqLLM schema is [arg: [type: :string, ...]]
    # Gemini expects OpenAPI schema format

    properties =
      Map.new(schema, fn {name, opts} ->
        {to_string(name), map_param_type(opts)}
      end)

    required =
      schema
      |> Enum.filter(fn {_name, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _} -> to_string(name) end)

    %{
      "type" => "OBJECT",
      "properties" => properties,
      "required" => required
    }
  end

  # Map empty schema
  defp map_parameters(_), do: %{"type" => "OBJECT", "properties" => %{}}

  defp map_param_type(opts) do
    type_atom = Keyword.get(opts, :type, :string)
    desc = Keyword.get(opts, :doc, "")

    type_str =
      case type_atom do
        :string -> "STRING"
        :integer -> "INTEGER"
        :float -> "NUMBER"
        :boolean -> "BOOLEAN"
        :array -> "ARRAY"
        _ -> "STRING"
      end

    %{
      "type" => type_str,
      "description" => desc
    }
  end
end
