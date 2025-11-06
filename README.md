<p align="center">
  <img src="assets/mcp_client.svg" alt="MCP Client Logo" width="200" height="200">
</p>

# MCP Client for Elixir

<!-- [![CI](https://github.com/nshkrdotcom/mcp_client/actions/workflows/elixir.yaml/badge.svg)](https://github.com/nshkrdotcom/mcp_client/actions/workflows/elixir.yaml) -->
[![Elixir](https://img.shields.io/badge/elixir-1.18.3-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/otp-27.2-blue.svg)](https://www.erlang.org)
[![Hex.pm](https://img.shields.io/hexpm/v/mcp_client.svg)](https://hex.pm/packages/mcp_client)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/mcp_client)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Canonical Model Context Protocol client for the Elixir ecosystem with first-class transports, tooling, and documentation.

## ✨ Highlights

- **Unified transports**: WebSocket, SSE, and raw TCP adapters with shared backoff + tombstone semantics
- **Declarative tools**: Type-safe wrappers for tool declaration, invocation, and validation
- **Observability-first**: Telemetry events for every hop plus structured, redactable logging helpers
- **Production ergonomics**: Configurable retry windows, circuit breakers, and connection watchdogs
- **Docs as product**: ExDoc assets, architecture guides, and SVG branding ship with the library

## 📦 Installation

Add `mcp_client` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:mcp_client, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## 🚀 Quick Start

1. Configure your MCP server credentials in `config/runtime.exs`
2. Start a connection with `MCPClient.start_link/1`
3. Declare tools with `MCPClient.Tools.declare/1` and register handlers
4. Stream responses with built-in supervision, telemetry, and retries

Full guides and API docs will be published on HexDocs as the project matures.

## 🧪 Development

```bash
mix test
mix credo --strict
MIX_ENV=test mix coveralls.html
```

Dialyzer PLTs live in `priv/plts` (ignored in the Hex package) so shared CI nodes stay fast.

## 🤝 Contributing

Issues and PRs are welcome! Please open a discussion first for sizeable protocol or API changes so we can align on design.
