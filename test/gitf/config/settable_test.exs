defmodule GiTF.Config.SettableTest do
  @moduledoc """
  The allow-list is a security boundary.

  A key reachable from here is a key reachable by anyone who compromises a
  Discord account, so these tests exist to make widening it a deliberate act
  with a failing test attached rather than an edit nobody notices.
  """
  use ExUnit.Case, async: true

  alias GiTF.Config.Settable

  describe "what may never be set" do
    test "secrets are refused even when spelled plausibly" do
      for key <- ~w(
            llm.keys.anthropic
            github_webhook_secret
            jira_webhook_secret
            server.api_key
            discord.token_env
            some.auth.setting
            db_password
          ) do
        assert {:error, :secret_shaped} = Settable.validate(key, "value"),
               "#{key} was not recognised as secret-shaped"
      end
    end

    test "nothing that changes what is billed" do
      for key <- ~w(
            costs.budget_usd
            costs.daily_budget_usd
            llm.execution_mode
            llm.bedrock_models
            major.max_ghosts
          ) do
        assert {:error, :not_settable} = Settable.validate(key, "10"), key
      end
    end

    test "nothing that changes who may act" do
      for key <- ~w(cabinet.enabled plugins.channels.discord.operators server.url) do
        assert match?({:error, _}, Settable.validate(key, "x")), key
      end
    end

    test "an unknown key is refused rather than created" do
      assert {:error, :not_settable} = Settable.validate("features.invented_flag", true)
      assert {:error, :not_settable} = Settable.validate("totally.made.up", 1)
    end

    test "a non-binary key is refused" do
      assert {:error, :not_settable} = Settable.validate(:features, true)
      assert {:error, :not_settable} = Settable.validate(nil, true)
    end
  end

  describe "the secret check is independent of the allow-list" do
    test "no allow-listed key is itself secret-shaped" do
      # Belt and braces: if these two ever disagreed, an allow-listed key
      # would be permanently unreachable and the failure would be silent.
      for key <- Settable.keys() do
        refute Settable.secret_shaped?(key),
               "#{key} is allow-listed but the secret check refuses it"
      end
    end

    test "the check refuses anything it cannot read as a key" do
      assert Settable.secret_shaped?(nil)
      assert Settable.secret_shaped?(%{})
    end
  end

  describe "what may be set, and how values are read" do
    test "booleans accept both real booleans and their strings" do
      assert {:ok, [:features, :aramaki_enabled], true} =
               Settable.validate("features.aramaki_enabled", true)

      assert {:ok, _, false} = Settable.validate("features.aramaki_enabled", "false")

      assert {:error, {:bad_value, :boolean}} =
               Settable.validate("features.aramaki_enabled", "yes")
    end

    test "integers reject negatives and nonsense" do
      assert {:ok, [:aramaki, :max_concurrent], 3} =
               Settable.validate("aramaki.max_concurrent", 3)

      assert {:ok, _, 7} = Settable.validate("aramaki.max_concurrent", "7")
      assert {:error, {:bad_value, :integer}} = Settable.validate("aramaki.max_concurrent", -1)

      assert {:error, {:bad_value, :integer}} =
               Settable.validate("aramaki.max_concurrent", "lots")
    end

    test "lists accept an array or a comma-separated string" do
      assert {:ok, _, ["error", "fatal"]} =
               Settable.validate("aramaki.sentry_levels", ["error", "fatal"])

      assert {:ok, _, ["error", "fatal"]} =
               Settable.validate("aramaki.sentry_levels", "error, fatal")

      assert {:error, {:bad_value, :string_list}} =
               Settable.validate("aramaki.sentry_levels", [1, 2])
    end

    test "routing maps must be string => string" do
      assert {:ok, [:jira_project_to_sector], %{"PROJ" => "sec-1"}} =
               Settable.validate("jira_project_to_sector", %{"PROJ" => "sec-1"})

      assert {:error, {:bad_value, :string_map}} =
               Settable.validate("jira_project_to_sector", %{"PROJ" => 1})
    end

    test "a top-level key yields a single-element path, a sectioned key two" do
      # The handler dispatches on this shape to pick the right writer.
      assert {:ok, [:jira_project_to_sector], _} =
               Settable.validate("jira_project_to_sector", %{"A" => "b"})

      assert {:ok, [:features, :wire_enabled], _} =
               Settable.validate("features.wire_enabled", true)
    end

    test "every advertised key actually validates" do
      # A key in the list that no coercion accepts would be advertised to the
      # operator and then refuse every value they tried.
      sample = %{
        boolean: true,
        integer: 1,
        string: "x",
        string_list: ["a"],
        string_map: %{"a" => "b"}
      }

      for {key, {kind, _desc}} <- Settable.all() do
        assert {:ok, _, _} = Settable.validate(key, Map.fetch!(sample, kind)),
               "#{key} (#{kind}) rejected a valid #{kind}"
      end
    end
  end
end
