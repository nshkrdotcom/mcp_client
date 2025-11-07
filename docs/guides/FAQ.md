# Frequently Asked Questions

Common questions about using MCP Client.

---

## Usage Patterns

### What's the difference between Direct and Code Execution patterns?

MCP Client supports **two usage patterns** for interacting with MCP servers:

**Pattern A: Direct Tool Calls**
- Load all tool definitions into model context
- Model decides which tools to call
- Client executes tool calls through Connection.call/4
- Best for: < 50 tools, simple workflows

**Pattern B: Code Execution**
- Generate Elixir modules from MCP server tools
- Agent writes Elixir code using these modules
- Code executes in your application (data stays in memory)
- Best for: 100+ tools, complex workflows, privacy-sensitive operations

**Token efficiency example:**
- Direct: 150K tokens (tool definitions) + 50K (data) = 200K tokens
- Code Execution: 0 tokens (tools not in context) + 3 tokens (agent writes: `IO.puts("Done")`) = 3 tokens
- **98.7% reduction** in token usage

See [Advanced Patterns - Usage Patterns](ADVANCED_PATTERNS.md#usage-patterns-direct-vs-code-execution) for complete comparison.

### When should I use Direct vs Code Execution pattern?

**Use Direct pattern when:**
- Connecting to < 50 tools
- Simple request/response workflows
- Tool selection needs model reasoning
- You want simplicity (no code generation)

**Use Code Execution pattern when:**
- Connecting to 100+ tools (would exceed context window)
- Complex workflows (loops, conditionals, multi-step)
- Privacy-sensitive data (keep PII out of model context)
- Cost optimization (98.7% token reduction)
- Progressive tool discovery needed

**Example decision:**
```
Google Workspace (10 tools) → Direct ✅
Salesforce (200+ objects × 4 operations = 800+ tools) → Code Execution ✅
```

### How do I use the Code Execution pattern?

**Post-MVP feature** (coming soon). The pattern will work like this:

```elixir
# 1. Generate client modules from MCP server
mix mcp.gen.client --server my_mcp_server --output lib/mcp_servers/

# 2. In your agent code:
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
{:ok, _} = Salesforce.update_record(conn, "Lead", "00Q...", %{
  Notes: doc.content
})
IO.puts("Done")
```

**Agent sees:** 3 tokens (`IO.puts("Done")`)
**Not in context:** Tool definitions (0 tokens), document content (0 tokens)

For now, you can manually wrap Connection.call/4:
```elixir
defmodule MCPServers.GoogleDrive do
  def get_document(conn, id) do
    MCPClient.Connection.call(conn, "google_drive__get_document", %{documentId: id})
  end
end
```

See [CODE_EXECUTION_PATTERN.md](../design/CODE_EXECUTION_PATTERN.md) for complete details.

### Does Code Execution require changes to my MCP server?

**No!** Code Execution is a **client-side pattern**. Your MCP server doesn't change at all.

The pattern works by:
1. Reading tool definitions from MCP server (Connection.call/4)
2. Generating Elixir wrapper modules (post-MVP tooling)
3. Agent writes code using these modules
4. Code executes in your app, calling Connection.call/4 under the hood

The MCP server sees the exact same Connection.call/4 requests either way.

### Can I mix Direct and Code Execution patterns?

**Yes!** You can use both patterns in the same application:

```elixir
# Direct pattern for simple servers
{:ok, tools} = MCPClient.Tools.list(simple_conn)
{:ok, result} = MCPClient.Tools.call(simple_conn, "weather", %{city: "NYC"})

# Code Execution pattern for complex servers
alias MCPServers.Salesforce
{:ok, leads} = Salesforce.query(complex_conn, "SELECT * FROM Lead WHERE Status = 'New'")
```

Use Direct for servers with few tools, Code Execution for servers with many tools.

---

## General Questions

### What is MCP Client?

MCP Client is an Elixir library for connecting to Model Context Protocol (MCP) servers. It allows your Elixir/Phoenix applications to:
- Execute tools on MCP servers
- Read resources (files, databases, APIs)
- Use prompt templates
- Receive server notifications

### What is MCP (Model Context Protocol)?

MCP is a protocol for AI/LLM applications to communicate with external context providers (servers that expose tools, data, and capabilities). Think of it as a standard API for connecting AI assistants to external systems.

Learn more: https://spec.modelcontextprotocol.io/

### Which Elixir/OTP versions are supported?

- **Elixir:** 1.16 or later
- **OTP:** 27.2 or later

Tested on: Elixir 1.18.3, OTP 27.2

### Is MCP Client production-ready?

MCP Client MVP (v0.1.x) is designed for production use with:
- Automatic reconnection with exponential backoff
- Request/response correlation with timeouts
- Flow control to prevent memory exhaustion
- Comprehensive error handling

However, it's a new project. Test thoroughly in your environment before production deployment.

---

## Installation & Setup

### How do I install MCP Client?

Add to `mix.exs`:

```elixir
def deps do
  [
    {:mcp_client, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get`.

### Do I need to install MCP servers separately?

Yes. MCP servers are separate executables (Python, Node.js, Rust, etc.). Install them using their respective package managers:

```bash
# Python servers (using uvx)
uvx mcp-server-sqlite
uvx mcp-server-filesystem

# Node.js servers (using npx)
npx -y @modelcontextprotocol/server-memory
```

### How do I find MCP servers?

- Official servers: https://github.com/modelcontextprotocol/servers
- Community servers: https://github.com/topics/mcp-server
- Or build your own: https://spec.modelcontextprotocol.io/

### Can I use MCP Client without external servers?

No. MCP Client is a *client* library - it needs to connect to an MCP *server*. However, you can use the memory server for testing:

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {MCPClient.Transports.Stdio, cmd: "uvx", args: ["mcp-server-memory"]}
)
```

---

## Configuration

### How do I configure timeouts?

At connection level (global):

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {...},
  request_timeout: 60_000  # 60 seconds
)
```

Per-request (override):

```elixir
MCPClient.Tools.call(conn, "slow_tool", %{}, timeout: 120_000)
```

See [Configuration Guide](CONFIGURATION.md) for all options.

### How do I configure reconnection behavior?

Use backoff options:

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {...},
  backoff_min: 1_000,    # Start at 1 second
  backoff_max: 30_000,   # Max 30 seconds
  backoff_jitter: 0.2    # ±20% randomization
)
```

Backoff doubles on each failure: 1s → 2s → 4s → 8s → 16s → 30s (max)

### Can I use environment variables for configuration?

Yes, recommended pattern:

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {
    MCPClient.Transports.Stdio,
    cmd: System.get_env("MCP_CMD", "mcp-server"),
    args: String.split(System.get_env("MCP_ARGS", ""), " ")
  }
)
```

See [Configuration Guide](CONFIGURATION.md) for complete example.

---

## Usage

### How do I list available tools?

```elixir
{:ok, tools} = MCPClient.Tools.list(conn)

Enum.each(tools, fn tool ->
  IO.puts("#{tool.name}: #{tool.description}")
end)
```

### How do I call a tool?

```elixir
{:ok, result} = MCPClient.Tools.call(conn, "tool_name", %{
  arg1: "value1",
  arg2: "value2"
})

# Check if tool reported error
if result.isError do
  IO.puts("Tool failed: #{inspect(result.content)}")
else
  IO.puts("Tool succeeded: #{inspect(result.content)}")
end
```

### How do I read a resource?

```elixir
{:ok, contents} = MCPClient.Resources.read(conn, "file:///path/to/file.txt")

# Contents is a list of content items
Enum.each(contents.contents, fn content ->
  case content do
    %{"type" => "text", "text" => text} ->
      IO.puts(text)

    %{"type" => "image", "data" => data, "mimeType" => mime} ->
      # Handle image (base64 encoded)
      save_image(data, mime)
  end
end)
```

### How do I subscribe to resource updates?

```elixir
# Subscribe to resource
:ok = MCPClient.Resources.subscribe(conn, "file:///watched/file.txt")

# Set up notification handler when starting connection
{:ok, conn} = MCPClient.start_link(
  transport: {...},
  notification_handler: fn notification ->
    case MCPClient.NotificationRouter.route(notification) do
      {:resources, :updated, %{"uri" => uri}} ->
        IO.puts("Resource updated: #{uri}")
        # Re-read resource
        {:ok, contents} = MCPClient.Resources.read(conn, uri)
        process_update(contents)

      _ -> :ok
    end

    :ok
  end
)
```

### How do I use prompts?

```elixir
# List available prompts
{:ok, prompts} = MCPClient.Prompts.list(conn)

# Get a prompt with arguments
{:ok, result} = MCPClient.Prompts.get(conn, "summarize", %{
  text: "Long text to summarize...",
  max_length: 200
})

# Use the prompt messages with your LLM
messages = result.messages
# => [%{role: "user", content: %{type: "text", text: "..."}}]
```

---

## Error Handling

### What does {:error, %MCPClient.Error{type: :timeout}} mean?

The request exceeded the timeout limit. Solutions:

1. **Increase timeout:**
   ```elixir
   MCPClient.Tools.call(conn, tool, args, timeout: 60_000)
   ```

2. **Check server performance:** The server may be slow or overloaded.

3. **Verify network:** If using HTTP transport, check network latency.

### What does {:error, %MCPClient.Error{type: :connection_closed}} mean?

The connection to the server was lost. This can happen when:
- Server process crashed
- Network connection dropped (HTTP/SSE transport)
- Server was manually stopped

**What to do:**
- Connection automatically reconnects with backoff
- Retry the operation after a brief delay
- Check server logs for crash reasons

### What does {:error, %MCPClient.Error{type: :method_not_found}} mean?

The server doesn't recognize the method. Causes:
- Server doesn't implement the feature (check capabilities)
- Typo in method/tool/resource name
- Wrong server (connecting to different server than expected)

**Solutions:**
```elixir
# Check server capabilities
caps = MCPClient.server_capabilities(conn)
IO.inspect(caps)

# Check available tools
{:ok, tools} = MCPClient.Tools.list(conn)
tool_names = Enum.map(tools, & &1.name)
IO.inspect(tool_names)
```

### How do I check what capabilities a server supports?

```elixir
caps = MCPClient.server_capabilities(conn)

# Check specific capability
has_subscribe? = get_in(caps, ["resources", "subscribe"]) != nil

# Check all capabilities
IO.inspect(caps, label: "Server Capabilities")
```

### Should I retry on errors?

**Retry on:**
- `:timeout` - Server may be temporarily slow
- `:connection_closed` - Connection is reconnecting

**Don't retry on:**
- `:tool_not_found` - Won't succeed on retry
- `:invalid_params` - Fix parameters first
- `:method_not_found` - Server doesn't support it

See [Error Handling Guide](ERROR_HANDLING.md) for patterns.

---

## Transports

### When should I use stdio vs HTTP transport?

**Use stdio when:**
- Server is a local executable (Python, Node.js, Rust binary)
- Low latency required
- Process isolation is security boundary
- Example: mcp-server-sqlite, mcp-server-filesystem

**Use HTTP when:**
- Server is remote/cloud-based
- Need OAuth authentication
- Server already has HTTP API
- Example: Enterprise MCP services

### How do I use the stdio transport?

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {
    MCPClient.Transports.Stdio,
    cmd: "python",           # or "node", "uvx", "/path/to/binary"
    args: ["server.py"],
    env: [{"DEBUG", "1"}],
    cd: "/path/to/server"
  }
)
```

### How do I use the HTTP transport with OAuth?

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {
    MCPClient.Transports.HTTP,
    base_url: "https://mcp.example.com",
    oauth: %{
      client_id: System.get_env("MCP_CLIENT_ID"),
      client_secret: System.get_env("MCP_CLIENT_SECRET"),
      token_url: "https://auth.example.com/oauth/token",
      scope: "mcp:read mcp:write"
    }
  }
)
```

The transport automatically handles token acquisition and refresh.

### Can I use multiple transports simultaneously?

Yes! Start multiple connections:

```elixir
# Local server
{:ok, local_conn} = MCPClient.start_link(
  name: MyApp.LocalMCP,
  transport: {MCPClient.Transports.Stdio, cmd: "mcp-local"}
)

# Cloud server
{:ok, cloud_conn} = MCPClient.start_link(
  name: MyApp.CloudMCP,
  transport: {MCPClient.Transports.HTTP, base_url: "https://..."}
)

# Use different connections
MCPClient.Tools.list(MyApp.LocalMCP)
MCPClient.Tools.list(MyApp.CloudMCP)
```

---

## Performance

### How many concurrent requests can I make?

As many as you want - requests are multiplexed over a single connection. However:
- **One connection** = sequential request processing
- **Parallel requests** = use `Task.async`:

```elixir
tasks = Enum.map(tools, fn tool ->
  Task.async(fn ->
    MCPClient.Tools.call(conn, tool, %{})
  end)
end)

results = Enum.map(tasks, &Task.await/1)
```

### Should I cache results?

Depends on your use case:

**Cache when:**
- Results are expensive to compute
- Data changes infrequently
- Multiple requests for same data

**Don't cache when:**
- Data changes frequently
- Server is fast
- Results are small

See [Advanced Patterns - Caching](ADVANCED_PATTERNS.md#caching-strategies) for patterns.

### How do I optimize for high throughput?

1. **Connection pooling** (one connection per server type)
2. **Parallel requests** (Task.async)
3. **Caching** (cache expensive results)
4. **Batching** (batch multiple operations)

See [Advanced Patterns - Performance](ADVANCED_PATTERNS.md#performance-optimization).

---

## Debugging

### How do I see what's happening with my connection?

Enable debug logging:

```elixir
# In config/dev.exs
config :logger, :console,
  level: :debug
```

Inspect connection state:

```elixir
state = :sys.get_state(conn)
IO.inspect(state, label: "Connection State")
```

### How do I debug tool calls?

Log requests and responses:

```elixir
{:ok, tools} = MCPClient.Tools.list(conn)
IO.inspect(tools, label: "Available Tools", pretty: true)

result = MCPClient.Tools.call(conn, "tool_name", %{arg: "value"})
IO.inspect(result, label: "Tool Result", pretty: true)
```

### How do I see server logs?

Server logs go to stderr. Capture them:

```elixir
# Stdio transport captures stderr by default
# Check console for server output
```

Or run server manually in separate terminal:

```bash
python server.py
# Server logs appear here
```

### Why is my connection constantly reconnecting?

Possible causes:
1. **Server keeps crashing** - Check server logs
2. **Wrong command/args** - Verify server starts correctly
3. **Server exits immediately** - Check server expects stdio mode
4. **Port/network issues** - For HTTP transport, check connectivity

Debug:
```bash
# Test server manually
python server.py
# Should stay running, not exit immediately
```

---

## Production

### Should I supervise MCP connections?

**Yes!** Always supervise in production:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {MCPClient, mcp_config()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp mcp_config do
    [
      name: MyApp.MCPConnection,
      transport: {...},
      notification_handler: &MyApp.handle_notification/1
    ]
  end
end
```

### How do I monitor connection health?

```elixir
# Ping periodically
defmodule MyApp.HealthCheck do
  use GenServer

  def init(conn) do
    schedule_check()
    {:ok, conn}
  end

  def handle_info(:check, conn) do
    case MCPClient.Connection.call(conn, "ping", %{}, 5_000) do
      {:ok, _} ->
        Logger.debug("MCP connection healthy")

      {:error, _} ->
        Logger.error("MCP connection unhealthy")
        # Alert ops team
    end

    schedule_check()
    {:noreply, conn}
  end

  defp schedule_check do
    Process.send_after(self(), :check, 30_000)
  end
end
```

### How do I handle credentials securely?

**Never hardcode:**
```elixir
# ❌ Bad
transport: {HTTP, oauth: %{client_secret: "hardcoded"}}

# ✅ Good
transport: {HTTP, oauth: %{
  client_secret: System.get_env("MCP_CLIENT_SECRET")
}}
```

Use secrets management:
- **Development:** `.env` files (not committed)
- **Production:** Vault, AWS Secrets Manager, k8s secrets

### What about telemetry/metrics?

MCP Client emits telemetry events. Attach handlers:

```elixir
:telemetry.attach_many(
  "my-app-mcp",
  [
    [:mcp_client, :request, :start],
    [:mcp_client, :request, :stop],
    [:mcp_client, :request, :exception]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

See [Advanced Patterns - Monitoring](ADVANCED_PATTERNS.md#monitoring--observability).

---

## Troubleshooting

### Connection fails with "command not found"

**Problem:** Server executable not in PATH

**Solution:**
```elixir
# Use full path
transport: {Stdio, cmd: "/usr/local/bin/mcp-server"}

# Or find executable
case System.find_executable("mcp-server") do
  nil -> raise "mcp-server not found"
  path -> transport: {Stdio, cmd: path}
end
```

### "Frame too large" error

**Problem:** Server sent response > 16MB (default limit)

**Solutions:**
1. **Increase limit** (use cautiously):
   ```elixir
   transport: {Stdio, cmd: "...", max_frame_bytes: 67_108_864}  # 64MB
   ```

2. **Request pagination** from server (preferred)
3. **Use streaming** (post-MVP feature)

### Tools/resources not showing up

**Check server capabilities:**
```elixir
caps = MCPClient.server_capabilities(conn)
IO.inspect(caps)

# Server needs to advertise features:
# %{"tools" => %{...}, "resources" => %{...}}
```

### Performance is slow

**Diagnose:**
1. **Server performance:** Is server slow?
2. **Network latency:** Using HTTP? Check network
3. **Caching:** Are you caching results?
4. **Parallel requests:** Using Task.async?

See [Advanced Patterns - Performance](ADVANCED_PATTERNS.md#performance-optimization).

---

## Getting Help

### Where can I get help?

1. **Documentation:**
   - [Getting Started Guide](GETTING_STARTED.md)
   - [Configuration Guide](CONFIGURATION.md)
   - [Error Handling Guide](ERROR_HANDLING.md)
   - [Advanced Patterns](ADVANCED_PATTERNS.md)

2. **API Reference:** https://hexdocs.pm/mcp_client

3. **GitHub Issues:** Report bugs or request features

4. **MCP Specification:** https://spec.modelcontextprotocol.io/

### How do I report a bug?

Open a GitHub issue with:
- Elixir/OTP versions
- MCP Client version
- Server being used
- Minimal reproduction code
- Error messages/logs

### How do I request a feature?

Open a GitHub issue describing:
- Use case
- Why existing features don't work
- Proposed API (if applicable)

### Can I contribute?

Yes! Contributions welcome:
- Bug fixes
- Documentation improvements
- New features (discuss first in issue)

---

## Roadmap

### What features are planned?

**Post-MVP features:**
- WebSocket transport
- Connection pooling
- Async notification handlers
- Request cancellation
- Streaming responses
- Additional transports

See [ADR-0010: MVP Scope](../design/ADR-0010-mvp-scope-and-deferrals.md) for complete list.

### When will feature X be available?

Check GitHub milestones and issues. Priority based on:
- User demand
- Complexity
- MCP spec evolution

---

**Still have questions?** Open a GitHub issue or check the [API documentation](https://hexdocs.pm/mcp_client).
