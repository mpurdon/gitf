defmodule GiTF.Cabinet.JDMTest do
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.JDM

  defp decide(input_overrides) do
    input =
      Map.merge(%{"class" => "bug", "mode" => "normal", "over_cap" => false}, input_overrides)

    JDM.evaluate(JDM.default_rules(), input)
  end

  test "the default ruleset is a supported JDM document" do
    assert JDM.supported?(JDM.default_rules())
  end

  test "the plan's matrix, row by row" do
    assert {:ok, %{"action" => "wake"}, %{rule: _}} = decide(%{})

    assert {:ok, %{"action" => "wake"}, %{rule: _}} =
             decide(%{"class" => "bug", "mode" => "vacation"})

    assert {:ok, %{"action" => "wake"}, %{rule: _}} = decide(%{"class" => "pr_review"})
    assert {:ok, %{"action" => "queue"}, %{rule: _}} = decide(%{"class" => "feature"})

    assert {:ok, %{"action" => "queue"}, %{rule: _}} =
             decide(%{"class" => "feature", "mode" => "vacation"})

    assert {:ok, %{"action" => "drop"}, %{rule: _}} = decide(%{"class" => "noise"})
    assert {:ok, %{"action" => "drop"}, %{rule: _}} = decide(%{"class" => "ci"})
    assert {:ok, %{"action" => "queue"}, %{rule: _}} = decide(%{"mode" => "off"})
    assert {:ok, %{"action" => "queue"}, %{rule: _}} = decide(%{"over_cap" => true})
  end

  test "an unknown class falls through to the catch-all: queue" do
    assert {:ok, %{"action" => "queue"}, %{rule: _}} = decide(%{"class" => "surprise"})
  end

  test "numeric comparison cells" do
    doc = %{
      "nodes" => [
        %{"type" => "inputNode", "id" => "i"},
        %{
          "type" => "decisionTableNode",
          "id" => "t",
          "content" => %{
            "hitPolicy" => "first",
            "inputs" => [%{"id" => "c1", "field" => "spend"}],
            "outputs" => [%{"id" => "o1", "field" => "action"}],
            "rules" => [
              %{"c1" => ">= 100", "o1" => ~s("queue")},
              %{"c1" => "", "o1" => ~s("wake")}
            ]
          }
        },
        %{"type" => "outputNode", "id" => "o"}
      ]
    }

    assert {:ok, %{"action" => "queue"}, %{rule: 1}} = JDM.evaluate(doc, %{"spend" => 150})
    assert {:ok, %{"action" => "wake"}, %{rule: 2}} = JDM.evaluate(doc, %{"spend" => 12.5})
  end

  test "anything beyond one decision table is refused, not guessed" do
    doc = %{"nodes" => [%{"type" => "functionNode", "id" => "f"}]}
    assert {:error, :unsupported} = JDM.evaluate(doc, %{})
    refute JDM.supported?(doc)
  end

  test "garbage is an error, and errors are the caller's queue" do
    assert {:error, _} = JDM.evaluate(%{}, %{})
    assert {:error, _} = JDM.evaluate(%{"nodes" => "nope"}, %{})
  end
end
