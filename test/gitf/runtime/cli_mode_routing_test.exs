defmodule GiTF.Runtime.CliModeRoutingTest do
  # CLI mode has the same misroute failure shape as bedrock mode (msn-bf61a1):
  # the compile-time :llm default_models catalog (google) must not override
  # the mode tier map, because the claude CLI rejects provider-qualified
  # specs outright. These tests pin the cli tier map to bare CLI aliases and
  # the --model normalization that guards the spawn boundary.
  use ExUnit.Case, async: false

  alias GiTF.Runtime.{Claude, ModelResolver}

  defp with_mode(mode, fun) do
    prev = System.get_env("GITF_EXECUTION_MODE")
    System.put_env("GITF_EXECUTION_MODE", mode)
    # Isolate from the host machine's real config.toml: these tests assert
    # the UNCONFIGURED defaults, and a developer box may set its own
    # provider_priority or cli_models.
    prev_priority = GiTF.Config.Provider.get([:llm, :provider_priority])
    prev_cli_models = GiTF.Config.Provider.get([:llm, :cli_models])
    GiTF.Config.Provider.put([:llm, :provider_priority], nil)
    GiTF.Config.Provider.put([:llm, :cli_models], nil)

    try do
      fun.()
    after
      GiTF.Config.Provider.put([:llm, :provider_priority], prev_priority)
      GiTF.Config.Provider.put([:llm, :cli_models], prev_cli_models)

      if prev,
        do: System.put_env("GITF_EXECUTION_MODE", prev),
        else: System.delete_env("GITF_EXECUTION_MODE")
    end
  end

  describe "configured_models in cli mode" do
    test "tiers resolve to bare CLI aliases, not the api-mode google catalog" do
      with_mode("cli", fn ->
        assert ModelResolver.resolve("thinking") == "sonnet"
        assert ModelResolver.resolve("general") == "sonnet"
        assert ModelResolver.resolve("fast") == "haiku"
      end)
    end

    test "no tier or legacy alias resolves to a google model" do
      with_mode("cli", fn ->
        for name <- ["thinking", "general", "fast", "opus", "sonnet", "haiku"] do
          resolved = ModelResolver.resolve(name)
          refute resolved =~ "google", "#{name} resolved to #{inspect(resolved)}"
        end
      end)
    end

    test "[llm.cli_models] config overrides the defaults" do
      with_mode("cli", fn ->
        GiTF.Config.Provider.put([:llm, :cli_models], %{"thinking" => "opus"})

        try do
          assert ModelResolver.resolve("thinking") == "opus"
          assert ModelResolver.resolve("fast") == "haiku"
        after
          GiTF.Config.Provider.put([:llm, :cli_models], nil)
        end
      end)
    end

    test "api mode keeps the compile-time default catalog" do
      with_mode("api", fn ->
        assert ModelResolver.resolve("fast") == "google:gemini-2.5-flash"
      end)
    end
  end

  describe "plugin resolution by mode" do
    test "cli mode resolves the claude CLI plugin, api mode resolves reqllm" do
      prev = GiTF.Config.Provider.get([:plugins, :models, :default])
      GiTF.Config.Provider.put([:plugins, :models, :default], nil)

      try do
        with_mode("cli", fn ->
          assert GiTF.Runtime.Models.default_name() == "claude"

          assert {:ok, GiTF.Plugin.Builtin.Models.Claude} =
                   GiTF.Runtime.Models.resolve_plugin()
        end)

        with_mode("api", fn ->
          assert GiTF.Runtime.Models.default_name() == "reqllm"
        end)
      after
        GiTF.Config.Provider.put([:plugins, :models, :default], prev)
      end
    end
  end

  describe "cli_model_name/1" do
    test "bare aliases and Anthropic model IDs pass through" do
      assert Claude.cli_model_name("sonnet") == "sonnet"
      assert Claude.cli_model_name("claude-sonnet-4-6") == "claude-sonnet-4-6"
    end

    test "anthropic-qualified specs are stripped to the bare ID" do
      assert Claude.cli_model_name("anthropic:claude-sonnet-4-6") == "claude-sonnet-4-6"
    end

    test "specs from other providers are dropped so the CLI default applies" do
      assert Claude.cli_model_name("google:gemini-2.5-flash") == nil
      assert Claude.cli_model_name("ollama:qwen2.5-coder:7b") == nil

      assert Claude.cli_model_name(
               "arn:aws:bedrock:us-east-1:1:inference-profile/us.anthropic.claude-sonnet-4-6"
             ) == nil
    end
  end
end
