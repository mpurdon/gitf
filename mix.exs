defmodule GiTF.MixProject do
  use Mix.Project

  @version "0.65.149"

  def project do
    [
      app: :gitf,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def cli do
    [preferred_envs: ["gitf.test.e2e": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {GiTF.Application, []}
    ]
  end

  defp escript do
    [
      main_module: GiTF.CLI,
      name: "gitf",
      # Marks the runtime as an escript so Application.start can tell a
      # one-shot CLI invocation apart from mix/iex/tests/releases —
      # :escript.script_name/0 can't (it succeeds under mix too).
      emu_args: "-gitf_escript true"
    ]
  end

  defp releases do
    [
      gitf: [
        # Set RELEASE_TAR=1 at build time to also emit a deployable tarball
        # artifact (for non-Docker deploys).
        steps: if(System.get_env("RELEASE_TAR") == "1", do: [:assemble, :tar], else: [:assemble]),
        applications: [runtime_tools: :permanent],
        # Production deployments MUST set RELEASE_COOKIE to a stable secret
        # via the environment (see rel/vm.args.eex). We intentionally do NOT
        # derive a cookie from System.user_home!() here — in a container that
        # resolves to the builder's home, not the runtime host's, which made
        # the cookie effectively unstable across images. If RELEASE_COOKIE is
        # unset, OTP generates a random cookie at assembly time, which is
        # fine for single-node local use.
        vm_args: "rel/vm.args.eex"
      ]
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:heroicons, "~> 0.5"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:optimus, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:yaml_elixir, "~> 2.11"},
      # >= 0.5.17 encodes the EEF-CVE-2026-49755 (decompression bomb) fix in
      # the constraint itself, not just lock hygiene.
      {:req, "~> 0.5.17"},
      # Gemini Live API (bidirectional voice) — studio voice sessions (M4)
      {:gemini_ex, "~> 0.14"},
      {:floki, "~> 0.36"},
      {:ratatouille, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.6"},
      {:opentelemetry_exporter, "~> 1.9"},
      {:req_llm, "~> 1.6"},
      {:mox, "~> 1.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
