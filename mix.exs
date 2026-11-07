defmodule Tussle.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()
  @source_url "https://github.com/aggressive-labs/tussle"

  def project do
    [
      app: :tussle,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Tussle",
      description:
        "An Elixir server for the resumable upload protocol \"tus\" - maintained fork of the tus package",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Tussle.Application, []}
    ]
  end

  defp deps do
    [
      # Floor excludes Plug releases affected by CVE-2026-54892, CVE-2026-56813
      # and CVE-2026-56814 while staying permissive for downstream consumers.
      {:plug, ">= 1.15.4 and < 2.0.0"},
      {:ex_doc, "~> 0.23", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md LICENSE VERSION),
      licenses: ["BSD-3-Clause"],
      links: %{
        "GitHub" => @source_url,
        "Original package" => "https://hex.pm/packages/tus"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      api_reference: false,
      extras: [
        "README.md": [title: "Overview"],
        "docs/UPSTREAM_COMPAT.md": [title: "Upstream Compatibility"],
        LICENSE: [title: "License"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      authors: ["Jayson Vantuyl"],
      source_ref: "v#{@version}"
    ]
  end
end
