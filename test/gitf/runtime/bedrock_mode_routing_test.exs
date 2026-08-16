defmodule GiTF.Runtime.BedrockModeRoutingTest do
  # Regression tests for the msn-bf61a1 misroute: in bedrock mode, the
  # compile-time :llm default_models catalog (google) overrode the bedrock
  # tier map for "fast" and every legacy alias, sending fix-op retries to a
  # provider with no API key.
  use ExUnit.Case, async: false

  alias GiTF.Runtime.{ModelResolver, ProviderCircuit, ProviderManager}

  defp with_mode(mode, fun) do
    prev = System.get_env("GITF_EXECUTION_MODE")
    System.put_env("GITF_EXECUTION_MODE", mode)
    # Isolate from the host machine's real config.toml: these tests assert
    # the UNCONFIGURED defaults, and a developer box may set its own
    # provider_priority.
    prev_priority = GiTF.Config.Provider.get([:llm, :provider_priority])
    GiTF.Config.Provider.put([:llm, :provider_priority], nil)

    try do
      fun.()
    after
      GiTF.Config.Provider.put([:llm, :provider_priority], prev_priority)

      if prev,
        do: System.put_env("GITF_EXECUTION_MODE", prev),
        else: System.delete_env("GITF_EXECUTION_MODE")
    end
  end

  describe "configured_models in bedrock mode" do
    test "fast tier resolves to a bedrock model, not the api-mode google catalog" do
      with_mode("bedrock", fn ->
        resolved = ModelResolver.resolve("fast")

        assert String.starts_with?(resolved, "amazon_bedrock:") or
                 String.starts_with?(resolved, "arn:aws:bedrock:"),
               "fast resolved to #{inspect(resolved)}"

        refute resolved =~ "google"
      end)
    end

    test "legacy aliases (haiku/sonnet/opus) also stay on bedrock" do
      with_mode("bedrock", fn ->
        for alias_name <- ["haiku", "sonnet", "opus"] do
          resolved = ModelResolver.resolve(alias_name)
          refute resolved =~ "google", "#{alias_name} resolved to #{inspect(resolved)}"
        end
      end)
    end

    test "api mode keeps the compile-time default catalog" do
      with_mode("api", fn ->
        assert ModelResolver.resolve("fast") == "google:gemini-2.5-flash"
      end)
    end
  end

  describe "provider_priority mode defaults" do
    test "bedrock mode defaults priority to bedrock when unconfigured" do
      with_mode("bedrock", fn ->
        assert ProviderManager.provider_priority() == ["bedrock"]
      end)
    end

    test "api mode keeps the google default" do
      with_mode("api", fn ->
        assert ProviderManager.provider_priority() == ["google"]
      end)
    end
  end

  describe "circuit fallback candidates" do
    test "bedrock mode: a google model falls back to a bedrock model" do
      with_mode("bedrock", fn ->
        assert {:ok, model, "bedrock"} =
                 ProviderCircuit.find_available_model("google:gemini-2.5-flash")

        # Host config may override tier models with ARNs — both forms are bedrock.
        assert String.starts_with?(model, "amazon_bedrock:") or
                 String.starts_with?(model, "arn:aws:bedrock:")
      end)
    end
  end
end
