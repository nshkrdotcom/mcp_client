defmodule MCPClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/mcp_client"

  def project do
    [
      app: :mcp_client,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "MCP Client",
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Core runtime
      {:req, "~> 0.5.10"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:typed_struct, "~> 0.3"},

      # Tooling
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp description do
    """
    Canonical Elixir client for the Model Context Protocol (MCP) with production-ready
    transports, tool execution, tracing, and first-class documentation assets.
    """
  end

  defp docs do
    [
      main: "readme",
      name: "MCP Client",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/mcp_client.svg",
      extras: [
        "README.md"
      ],
      groups_for_modules: [
        "Public API": [MCPClient],
        Internals: []
      ]
    ]
  end

  defp package do
    [
      name: "mcp_client",
      description: description(),
      files: ~w(lib mix.exs README.md LICENSE assets),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "HexDocs" => "https://hexdocs.pm/mcp_client"
      },
      maintainers: ["nshkrdotcom"],
      exclude_patterns: [
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end
end
