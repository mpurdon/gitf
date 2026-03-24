defmodule GiTF.MixProject do
  use Mix.Project

  @version "0.36.7"

  def project do
    [
      app: :gitf,
      version: @version,
      elixir: "~> 1.15",
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
      name: "gitf"
    ]
  end

  defp releases do
    [
      gitf: [
        steps: [:assemble],
        applications: [runtime_tools: :permanent],
        cookie: "gitf_#{:erlang.phash2(System.user_home!())}"
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
      {:req, "~> 0.5"},
      {:ratatouille, "~> 0.5"},
      {:telemetry, "~> 1.2"},
      {:req_llm, "~> 1.6"},
      {:mox, "~> 1.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
