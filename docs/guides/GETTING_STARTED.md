# Getting Started with MCP Client

Complete guide to using the Elixir MCP Client library.

---

## Installation

Add `mcp_client` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:mcp_client, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

---

## Quick Start

### 1. Start a Connection

```elixir
# Connect to a local MCP server via stdio
{:ok, conn} = McpClient.start_link(
  transport: {
    McpClient.Transports.Stdio,
    cmd: "uvx",
    args: ["mcp-server-sqlite", "--db-path", "./test.db"]
  }
)
```

### 2. List Available Tools

```elixir
{:ok, tools} = McpClient.Tools.list(conn)

Enum.each(tools, fn tool ->
  IO.puts("Tool: #{tool.name} - #{tool.description}")
end)
```

### 3. Call a Tool

```elixir
{:ok, result} = McpClient.Tools.call(conn, "read_query", %{
  query: "SELECT * FROM users LIMIT 10"
})

Enum.each(result.content, fn content ->
  IO.puts(content["text"])
end)
```

### 4. Clean Up

```elixir
McpClient.stop(conn)
```

---

## Core Concepts

### Connections

A connection represents a persistent link to an MCP server. Connections:
- Automatically initialize with capability negotiation
- Handle reconnection on failure (with exponential backoff)
- Manage request/response correlation
- Deliver server notifications to handlers

**Lifecycle:**
```
:starting → :initializing → :ready → (:backoff if failure) → :closing
```

### Transports

Transports handle the physical communication layer:

**Stdio** (local processes):
```elixir
{McpClient.Transports.Stdio, cmd: "python", args: ["server.py"]}
```

**SSE** (server-sent events, receive only):
```elixir
{McpClient.Transports.SSE, url: "https://api.example.com/sse"}
```

**HTTP+SSE** (bidirectional, cloud servers):
```elixir
{McpClient.Transports.HTTP,
 base_url: "https://api.example.com",
 headers: [{"authorization", "Bearer #{token}"}]}
```

### MCP Primitives

**Tools** - Executable functions exposed by server:
```elixir
McpClient.Tools.list(conn)
McpClient.Tools.call(conn, "tool_name", %{arg: "value"})
```

**Resources** - Data sources (files, URLs, database queries):
```elixir
McpClient.Resources.list(conn)
McpClient.Resources.read(conn, "file:///path/to/file")
McpClient.Resources.subscribe(conn, "file:///watched/file")
```

**Prompts** - LLM prompt templates:
```elixir
McpClient.Prompts.list(conn)
McpClient.Prompts.get(conn, "prompt_name", %{arg: "value"})
```

---

## Choosing Your Usage Pattern

MCP Client supports **two usage patterns** that affect how your agent interacts with MCP servers:

### Pattern A: Direct Tool Calls (MVP - Available Now)

Load tool definitions into model context, model calls tools directly:

```elixir
# 1. List all tools (definitions go into model context)
{:ok, tools} = McpClient.Tools.list(conn)
# Model sees: 150K tokens of tool definitions

# 2. Model decides to call a tool
{:ok, result} = McpClient.Tools.call(conn, "google_drive__get_document", %{
  documentId: "abc123"
})
# Model sees: 50K tokens of document content

# 3. Model decides to call another tool
{:ok, _} = McpClient.Tools.call(conn, "salesforce__update_record", %{...})
```

**When to use:**
- Connecting to < 50 tools
- Simple request/response workflows
- Model needs to reason about which tools to use
- You want simplicity

### Pattern B: Code Execution (Post-MVP)

Generate Elixir modules, agent writes code that executes in your app:

```elixir
# 1. Generate modules (one-time setup)
# mix mcp.gen.client --server gdrive --output lib/mcp_servers/

# 2. Agent writes Elixir code
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
{:ok, _} = Salesforce.update_record(conn, "Lead", "00Q...", %{Notes: doc.content})
IO.puts("Done")
```

**Agent sees:** 3 tokens (`IO.puts("Done")`)
**Not in context:** Tool definitions (0 tokens), data (0 tokens)
**Token reduction:** 98.7% (200K → 3K tokens)

**When to use:**
- Connecting to 100+ tools (would exceed context window)
- Complex workflows (loops, conditionals, multi-step operations)
- Privacy-sensitive data (keep PII out of model context)
- Cost optimization (75× cheaper on large tool sets)

### Quick Decision Guide

| Scenario | Pattern | Reason |
|----------|---------|--------|
| Google Workspace (10 tools) | Direct ✅ | Few tools, simple workflows |
| Salesforce (800+ tools) | Code Execution ✅ | Many tools, exceeds context |
| Healthcare app (PII data) | Code Execution ✅ | Keep sensitive data out of context |
| Weather API (1 tool) | Direct ✅ | Single tool, no benefit from codegen |
| Financial workflow (loops/conditions) | Code Execution ✅ | Complex control flow |

**For MVP:** Use **Pattern A (Direct)**. Code Execution is a post-MVP feature (coming soon).

**Current workaround:** You can manually wrap Connection.call/4 to simulate Pattern B:

```elixir
defmodule MCPServers.GoogleDrive do
  def get_document(conn, document_id) do
    McpClient.Connection.call(conn, "google_drive__get_document", %{
      documentId: document_id
    })
  end
end

# Agent writes code using your wrappers
alias MCPServers.GoogleDrive
{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
```

See [CODE_EXECUTION_PATTERN.md](../design/CODE_EXECUTION_PATTERN.md) for complete details.

---

## Common Patterns

### Supervised Connection

Add to your application supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {McpClient,
       name: MyApp.MCPConnection,
       transport: {McpClient.Transports.Stdio, cmd: "mcp-server"}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Access the connection:

```elixir
conn = Process.whereis(MyApp.MCPConnection)
McpClient.Tools.list(conn)
```

### Handling Notifications

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: fn notification ->
    case McpClient.NotificationRouter.route(notification) do
      {:resources, :updated, %{"uri" => uri}} ->
        Logger.info("Resource updated: #{uri}")
        MyApp.ResourceCache.invalidate(uri)

      {:tools, :list_changed, _params} ->
        Logger.info("Tools changed, refreshing...")
        Task.start(fn -> refresh_tools(conn) end)

      {:logging, :message, %{"level" => level, "data" => data}} ->
        Logger.log(String.to_existing_atom(level), "[MCP] #{inspect(data)}")

      _ -> :ok
    end
  end
)
```

### Error Handling

All operations return `{:ok, result} | {:error, %McpClient.Error{}}`:

```elixir
case McpClient.Tools.call(conn, "search", %{query: "test"}) do
  {:ok, result} ->
    process_result(result)

  {:error, %McpClient.Error{type: :timeout}} ->
    Logger.warn("Tool call timed out, retrying...")
    retry_with_backoff()

  {:error, %McpClient.Error{type: :tool_not_found}} ->
    Logger.error("Tool does not exist")

  {:error, %McpClient.Error{type: :connection_closed}} ->
    Logger.error("Connection lost, will reconnect automatically")

  {:error, error} ->
    Logger.error("Tool call failed: #{inspect(error)}")
end
```

### Configuration

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mcp-server"},
  request_timeout: 30_000,      # 30 seconds per request
  init_timeout: 10_000,          # 10 seconds for initialize
  backoff_min: 1_000,            # Min reconnect delay
  backoff_max: 30_000,           # Max reconnect delay
  max_frame_bytes: 16_777_216,   # 16MB frame limit
  notification_handler: &handle_notification/1
)
```

See [Configuration Guide](CONFIGURATION.md) for all options.

---

## Examples by Use Case

### File System Operations

```elixir
# Connect to filesystem server
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio,
              cmd: "uvx",
              args: ["mcp-server-filesystem", "/path/to/root"]}
)

# List files
{:ok, resources} = McpClient.Resources.list(conn)

# Read file
file = Enum.find(resources, & &1.name == "README.md")
{:ok, contents} = McpClient.Resources.read(conn, file.uri)

IO.puts(List.first(contents.contents)["text"])

# Watch for changes
:ok = McpClient.Resources.subscribe(conn, file.uri)
```

### Database Queries

```elixir
# Connect to SQLite server
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio,
              cmd: "uvx",
              args: ["mcp-server-sqlite", "--db-path", "./app.db"]}
)

# List available tools
{:ok, tools} = McpClient.Tools.list(conn)

# Execute query
{:ok, result} = McpClient.Tools.call(conn, "read_query", %{
  query: "SELECT * FROM users WHERE created_at > date('now', '-7 days')"
})

# Parse results
result.content
|> Enum.filter(& &1["type"] == "text")
|> Enum.each(&IO.puts(&1["text"]))
```

### LLM Prompts

```elixir
# Server that provides prompt templates
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mcp-prompt-server"}
)

# List prompts
{:ok, prompts} = McpClient.Prompts.list(conn)

# Get prompt with arguments
{:ok, prompt_result} = McpClient.Prompts.get(conn, "summarize", %{
  text: "Long document text...",
  max_length: 200
})

# Use messages with LLM
messages = prompt_result.messages
# => [%{role: "user", content: %{type: "text", text: "..."}}]

# Send to LLM (using your preferred LLM client)
```

### Cloud/Remote Servers

```elixir
# OAuth 2.1 authenticated connection
{:ok, conn} = McpClient.start_link(
  transport: {
    McpClient.Transports.HTTP,
    base_url: "https://mcp.example.com",
    oauth: %{
      client_id: System.get_env("MCP_CLIENT_ID"),
      client_secret: System.get_env("MCP_CLIENT_SECRET"),
      token_url: "https://auth.example.com/oauth/token",
      scope: "mcp:read mcp:write"
    }
  }
)

# Use exactly like local servers
{:ok, tools} = McpClient.Tools.list(conn)
```

---

## Testing Your Integration

### Unit Tests

Mock the connection:

```elixir
defmodule MyApp.ToolExecutorTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  test "executes tool successfully" do
    MockConnection
    |> expect(:call, fn _conn, "tools/call", params, _timeout ->
      {:ok, %{"content" => [%{"type" => "text", "text" => "Success"}], "isError" => false}}
    end)

    assert {:ok, result} = MyApp.ToolExecutor.run(MockConnection, "my_tool", %{})
    assert result == "Success"
  end
end
```

### Integration Tests

Test with real servers:

```elixir
@moduletag :integration
test "lists tools from real server" do
  {:ok, conn} = McpClient.start_link(
    transport: {McpClient.Transports.Stdio, cmd: "mcp-test-server"}
  )

  assert {:ok, tools} = McpClient.Tools.list(conn)
  assert length(tools) > 0

  McpClient.stop(conn)
end
```

---

## Troubleshooting

### Connection Fails

**Issue:** `{:error, %Error{type: :connection_closed}}`

**Solutions:**
- Check server executable is in PATH
- Verify server command and arguments
- Check server logs (stderr)
- Try running server manually: `uvx mcp-server-name --help`

### Timeout Errors

**Issue:** `{:error, %Error{type: :timeout}}`

**Solutions:**
- Increase `request_timeout` option
- Check server performance
- Verify network connectivity (for remote servers)

### Method Not Found

**Issue:** `{:error, %Error{type: :method_not_found}}`

**Solutions:**
- Check server capabilities: `McpClient.server_capabilities(conn)`
- Verify feature is supported by server
- Check MCP server documentation

### Invalid Response

**Issue:** `{:error, %Error{type: :invalid_response}}`

**Solutions:**
- Update MCP server to latest version
- Check protocol version compatibility
- Review server logs for errors

---

## Next Steps

- [Configuration Guide](CONFIGURATION.md) - Complete configuration options
- [Error Handling Guide](ERROR_HANDLING.md) - Comprehensive error handling
- [Advanced Patterns](ADVANCED_PATTERNS.md) - Connection pooling, caching, etc.
- [API Reference](https://hexdocs.pm/mcp_client) - Complete API documentation

---

## Resources

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **Official MCP Servers**: https://github.com/modelcontextprotocol/servers
- **Example Applications**: `examples/` directory
- **Community Servers**: https://github.com/topics/mcp-server

---

**Questions?** Open an issue on GitHub or check the [FAQ](FAQ.md).
