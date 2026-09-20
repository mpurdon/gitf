defmodule GiTF.SecretsTest do
  @moduledoc """
  These tests run with no AWS credentials, which is the point: the machine
  running them is the same shape as a laptop, and the contract is that a
  laptop behaves exactly as it did before this module existed.

  There is no test here that exercises a successful SSM fetch. That would
  need either a signed-request stub in front of Req or real credentials, and
  neither proves the thing that actually matters — that a failure to reach
  Parameter Store is indistinguishable from the secret being absent. The live
  path is verified against the box instead, via `sources/0`.
  """
  use ExUnit.Case, async: false

  alias GiTF.Secrets

  setup do
    on_exit(fn -> Secrets.expire(:all) end)
    Secrets.expire(:all)
    :ok
  end

  describe "the environment wins" do
    test "a set variable is returned without any AWS involvement" do
      System.put_env("GITF_SYSTEM_ONE_API_KEY", "from-env")
      on_exit(fn -> System.delete_env("GITF_SYSTEM_ONE_API_KEY") end)

      assert Secrets.get("GITF_SYSTEM_ONE_API_KEY") == "from-env"
      assert {"GITF_SYSTEM_ONE_API_KEY", :env} in Secrets.sources()
    end

    test "an empty or whitespace variable counts as unset" do
      # Otherwise `GITF_SYSTEM_ONE_API_KEY=` in the env file — the shape a
      # commented-out template line becomes when uncommented and not filled —
      # would shadow the parameter with an empty string.
      for blank <- ["", "   ", "\n"] do
        System.put_env("GITF_SYSTEM_ONE_API_KEY", blank)
        Secrets.expire(:all)
        assert Secrets.get("GITF_SYSTEM_ONE_API_KEY") == nil, inspect(blank)
      end

      System.delete_env("GITF_SYSTEM_ONE_API_KEY")
    end

    test "a value with surrounding whitespace is trimmed" do
      System.put_env("GITHUB_TOKEN", "  ghp_padded  ")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      assert Secrets.get("GITHUB_TOKEN") == "ghp_padded"
    end
  end

  describe "with no AWS credentials" do
    test "every known secret resolves to nil rather than raising" do
      for name <- Secrets.known() do
        System.delete_env(name)
      end

      Secrets.expire(:all)

      for name <- Secrets.known() do
        assert Secrets.get(name) == nil, "#{name} did not resolve to nil"
      end
    end

    test "the negative result is cached, so the timeout is paid once" do
      System.delete_env("GITF_SENTRY_WEBHOOK_SECRET")
      Secrets.expire(:all)

      assert Secrets.get("GITF_SENTRY_WEBHOOK_SECRET") == nil

      # A cached miss must answer immediately. Without the negative cache this
      # is an IMDS connect attempt per call, on every webhook request.
      {micros, nil} = :timer.tc(fn -> Secrets.get("GITF_SENTRY_WEBHOOK_SECRET") end)
      assert micros < 50_000, "a cached miss took #{micros}µs — the negative cache is not working"
    end

    test "fetch!/1 says where it looked" do
      System.delete_env("GITF_SYSTEM_ONE_API_KEY")
      Secrets.expire(:all)

      assert_raise RuntimeError, ~r{/gitf/system_one_api_key}, fn ->
        Secrets.fetch!("GITF_SYSTEM_ONE_API_KEY")
      end
    end
  end

  describe "an unknown name" do
    test "still reads the environment, so it is a safe drop-in" do
      System.put_env("SOME_UNMAPPED_THING", "value")
      on_exit(fn -> System.delete_env("SOME_UNMAPPED_THING") end)

      assert Secrets.get("SOME_UNMAPPED_THING") == "value"
    end

    test "is never looked up in Parameter Store" do
      # Guessing a path would turn a typo into an AWS call instead of a nil.
      refute "SOME_UNMAPPED_THING" in Secrets.known()
      System.delete_env("SOME_UNMAPPED_THING")
      assert Secrets.get("SOME_UNMAPPED_THING") == nil
    end
  end

  describe "what must never be resolvable here" do
    test "provider API keys are not known secrets" do
      # A key parked in Parameter Store — an action that reads as safe
      # storage — must not be able to flip an in-process consumer from the
      # subscription onto a metered API with no flag and no announcement.
      for key <- ~w(ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY AWS_SECRET_ACCESS_KEY) do
        refute key in Secrets.known(), "#{key} must not be resolvable from Parameter Store"
      end
    end
  end

  describe "rotation" do
    test "expire/1 drops one secret and leaves the others" do
      System.put_env("GITHUB_TOKEN", "first")
      assert Secrets.get("GITHUB_TOKEN") == "first"

      System.put_env("GITHUB_TOKEN", "second")
      # Env is read live, never cached — only SSM results are.
      assert Secrets.get("GITHUB_TOKEN") == "second"

      assert Secrets.expire("GITHUB_TOKEN") == :ok
      assert Secrets.get("GITHUB_TOKEN") == "second"

      System.delete_env("GITHUB_TOKEN")
    end

    test "sources/0 reports where each secret came from, and no values" do
      System.put_env("GITHUB_TOKEN", "ghp_secret_value")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      sources = Secrets.sources()

      assert {"GITHUB_TOKEN", :env} in sources
      assert Enum.all?(sources, fn {_name, source} -> source in [:env, :ssm, :absent] end)

      refute sources |> inspect() |> String.contains?("ghp_secret_value"),
             "sources/0 leaked a secret value"
    end
  end
end
