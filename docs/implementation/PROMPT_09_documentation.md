# Implementation Prompt 09: Documentation and README

**Goal:** Create comprehensive user-facing documentation including README, usage examples, and configuration guide.

**Test Strategy:** Documentation must be accurate, complete, and match actual implementation.

---

## Context: What You're Building

You're creating the final user-facing documentation that:
1. **README.md**: Project overview, quick start, API reference
2. **Usage examples**: Common patterns and recipes
3. **Configuration guide**: All options explained
4. **Troubleshooting**: Common issues and solutions

This documentation is for library users, not contributors.

---

## Required Reading: MVP Scope

From MVP_SPEC.md and ADR-0010:

### MVP Features (Document These)

**Transports:**
- Stdio (subprocess via Port)

**MCP Methods:**
- Tools: list, call
- Resources: list, read, templates/list
- Prompts: list, get
- General: ping

**Reliability:**
- Automatic reconnection with exponential backoff
- Request timeout handling
- Transport busy retry (3 attempts)
- Tombstone-based duplicate prevention

**Configuration:**
- All timeout values
- Backoff parameters
- Retry parameters
- Notification handlers

### NOT in MVP (Don't Document)

- SSE/HTTP transports
- Session IDs or session management
- Async notification handlers
- Connection pooling
- Request cancellation API
- Telemetry (mentioned but not required)

---

## Implementation Requirements

### 1. Main README

**File: `README.md`**

```markdown
# McpClient

Elixir client library for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/).

MCP is a protocol for connecting AI assistants to external tools, resources, and prompts. This client library allows Elixir applications to act as MCP clients, connecting to MCP servers over stdio (with SSE/HTTP support planned for future releases).

## Features

- ✅ **Full MCP Support**: Tools, Resources, Prompts, and Notifications
- ✅ **Reliable**: Automatic reconnection, request timeouts, retry logic
- ✅ **Simple API**: Clean, synchronous Elixir interface
- ✅ **OTP-Native**: Built with gen_statem, follows supervision best practices
- ✅ **Well-Tested**: Comprehensive test coverage with property tests

## Installation

Add `mcp_client` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mcp_client, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Start a client connecting to an MCP server
{:ok, client} = McpClient.start_link(
  transport: :stdio,
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-everything"]
)

# List available tools
{:ok, %{"tools" => tools}} = McpClient.list_tools(client)

# Call a tool
{:ok, result} = McpClient.call_tool(client, "get_weather", %{
  "city" => "New York"
})

# Read a resource
{:ok, content} = McpClient.read_resource(client, "file:///path/to/file")

# List prompts
{:ok, %{"prompts" => prompts}} = McpClient.list_prompts(client)

# Clean shutdown
:ok = McpClient.stop(client)
```

## Configuration

All configuration options:

```elixir
McpClient.start_link([
  # Transport (required)
  transport: :stdio,              # Only :stdio in v0.1
  command: "npx",                 # Command to execute
  args: ["-y", "my-mcp-server"],  # Command arguments
  env: [],                        # Environment variables (optional)

  # Timeouts
  request_timeout: 30_000,        # Request timeout in ms (default: 30s)
  init_timeout: 10_000,           # Initialize timeout in ms (default: 10s)

  # Reconnection
  backoff_min: 1_000,             # Min backoff delay in ms (default: 1s)
  backoff_max: 30_000,            # Max backoff delay in ms (default: 30s)

  # Retry (for busy transport)
  retry_attempts: 3,              # Max send attempts (default: 3)
  retry_delay_ms: 10,             # Base retry delay in ms (default: 10ms)
  retry_jitter: 0.5,              # Retry jitter factor (default: 0.5 = ±50%)

  # Notifications
  notification_handlers: [handler_fn],  # List of handler functions

  # Advanced
  max_frame_bytes: 16_777_216,    # Max frame size (default: 16MB)
  tombstone_sweep_ms: 60_000      # Tombstone cleanup interval (default: 60s)
])
```

## API Reference

### Lifecycle

#### `start_link/1`

Start an MCP client connection.

**Options:** See Configuration section above.

**Returns:** `{:ok, pid()}` or `{:error, term()}`

```elixir
{:ok, client} = McpClient.start_link(
  transport: :stdio,
  command: "python",
  args: ["server.py"]
)
```

#### `stop/1`

Stop the client gracefully.

**Returns:** `:ok`

```elixir
:ok = McpClient.stop(client)
```

### Tools

#### `list_tools/1`

List available tools from the server.

**Returns:** `{:ok, %{"tools" => [tool]}}` or `{:error, error}`

```elixir
{:ok, %{"tools" => tools}} = McpClient.list_tools(client)

for tool <- tools do
  IO.puts("#{tool["name"]}: #{tool["description"]}")
end
```

#### `call_tool/3`

Call a tool with arguments.

**Arguments:**
- `name` - Tool name (string)
- `arguments` - Tool arguments (map)
- `opts` - Options (keyword list, optional)

**Returns:** `{:ok, result}` or `{:error, error}`

```elixir
{:ok, weather} = McpClient.call_tool(client, "get_weather", %{
  "city" => "San Francisco",
  "units" => "celsius"
})
```

**Custom timeout:**

```elixir
{:ok, result} = McpClient.call_tool(client, "slow_operation", %{},
  timeout: 60_000  # 60 seconds
)
```

### Resources

#### `list_resources/1`

List available resources.

**Returns:** `{:ok, %{"resources" => [resource]}}` or `{:error, error}`

```elixir
{:ok, %{"resources" => resources}} = McpClient.list_resources(client)
```

#### `read_resource/2`

Read a resource by URI.

**Arguments:**
- `uri` - Resource URI (string)
- `opts` - Options (keyword list, optional)

**Returns:** `{:ok, content}` or `{:error, error}`

```elixir
{:ok, %{"contents" => contents}} = McpClient.read_resource(
  client,
  "file:///project/README.md"
)
```

#### `list_resource_templates/1`

List resource templates.

**Returns:** `{:ok, %{"resourceTemplates" => [template]}}` or `{:error, error}`

### Prompts

#### `list_prompts/1`

List available prompts.

**Returns:** `{:ok, %{"prompts" => [prompt]}}` or `{:error, error}`

```elixir
{:ok, %{"prompts" => prompts}} = McpClient.list_prompts(client)
```

#### `get_prompt/3`

Get a prompt with arguments.

**Arguments:**
- `name` - Prompt name (string)
- `arguments` - Prompt arguments (map, optional)
- `opts` - Options (keyword list, optional)

**Returns:** `{:ok, prompt}` or `{:error, error}`

```elixir
{:ok, prompt} = McpClient.get_prompt(client, "code_review", %{
  "language" => "elixir",
  "style" => "functional"
})
```

### General

#### `ping/1`

Ping the server.

**Returns:** `{:ok, %{}}` or `{:error, error}`

```elixir
{:ok, _} = McpClient.ping(client)
```

## Error Handling

All functions return `{:ok, result}` or `{:error, %McpClient.Error{}}`.

Error struct:

```elixir
%McpClient.Error{
  type: :transport | :timeout | :unavailable | :shutdown | :server | :protocol,
  message: String.t(),
  details: map()
}
```

**Error kinds:**

- `:transport` - Connection failure, transport down
- `:timeout` - Request timeout
- `:unavailable` - Connection in backoff, not ready
- `:shutdown` - Connection shutting down
- `:server` - Server returned error
- `:protocol` - Protocol violation

**Example error handling:**

```elixir
case McpClient.call_tool(client, "tool", %{}) do
  {:ok, result} ->
    # Process result
    IO.inspect(result)

  {:error, %McpClient.Error{type: :timeout}} ->
    # Handle timeout
    Logger.warn("Tool call timed out")

  {:error, %McpClient.Error{type: :server, message: msg}} ->
    # Handle server error
    Logger.error("Server error: #{msg}")

  {:error, error} ->
    # Handle other errors
    Logger.error("Unexpected error: #{inspect(error)}")
end
```

## Notification Handlers

Register handlers to receive server notifications:

```elixir
handler = fn notification ->
  %{method: method, params: params} = notification
  IO.puts("Notification: #{method}")
  IO.inspect(params)
end

{:ok, client} = McpClient.start_link(
  transport: :stdio,
  command: "server",
  notification_handlers: [handler]
)
```

**Handler signature:**

```elixir
@type notification :: %{method: String.t(), params: map()}
@type handler :: (notification() -> any())
```

**Note:** Handlers execute synchronously in the connection process. Keep them fast.

## Examples

### Using with Livebook

```elixir
Mix.install([{:mcp_client, "~> 0.1.0"}])

{:ok, client} = McpClient.start_link(
  transport: :stdio,
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-everything"]
)

{:ok, tools} = McpClient.list_tools(client)
Kino.DataTable.new(tools["tools"])
```

### Building an AI Agent

```elixir
defmodule MyAgent do
  def run do
    {:ok, client} = McpClient.start_link(
      transport: :stdio,
      command: "python",
      args: ["tools/server.py"]
    )

    # Get available tools
    {:ok, %{"tools" => tools}} = McpClient.list_tools(client)

    # Execute agent loop
    loop(client, tools)
  end

  defp loop(client, tools) do
    # Your agent logic here
    # Call tools based on LLM decisions
    {:ok, result} = McpClient.call_tool(client, "selected_tool", arguments)
    # ...
  end
end
```

### Error Retry Pattern

```elixir
defmodule Helpers do
  def retry_request(fun, attempts \\ 3) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %McpClient.Error{type: :timeout}} when attempts > 1 ->
        Process.sleep(1000)
        retry_request(fun, attempts - 1)

      {:error, error} ->
        {:error, error}
    end
  end
end

# Usage
result = Helpers.retry_request(fn ->
  McpClient.call_tool(client, "unreliable_tool", %{})
end)
```

## Troubleshooting

### Connection keeps reconnecting

**Cause:** Server process is crashing or not responding to initialize.

**Solution:**
- Check server logs
- Verify command and args are correct
- Test command manually: `npx -y your-server`
- Increase init_timeout if server is slow to start

### Requests timing out

**Cause:** Server is slow or unresponsive.

**Solution:**
- Increase request_timeout in configuration
- Or pass timeout per-request: `McpClient.call_tool(client, "tool", %{}, timeout: 60_000)`

### "Transport busy after 3 attempts"

**Cause:** Server is overloaded or transport buffer is full.

**Solution:**
- Reduce request rate
- Increase retry_attempts in configuration
- Check server performance

### Notifications not being received

**Cause:** Handler not registered or handler crashing.

**Solution:**
- Verify notification_handlers is set in start_link
- Wrap handler in try/rescue to catch errors
- Check logs for handler crashes

## Roadmap

- [ ] SSE transport (HTTP + Server-Sent Events)
- [ ] HTTP transport (direct HTTP)
- [ ] Request cancellation API
- [ ] Async notification handlers
- [ ] Telemetry integration
- [ ] Connection pooling

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and contribution guidelines.

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.

## Links

- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [MCP Servers Directory](https://github.com/modelcontextprotocol/servers)
- [Hex Package](https://hex.pm/packages/mcp_client)
- [Documentation](https://hexdocs.pm/mcp_client)
```

---

### 2. Usage Examples File

**File: `examples/usage.exs`**

```elixir
# McpClient Usage Examples
# Run with: elixir examples/usage.exs

Mix.install([{:mcp_client, path: "."}])

# Example 1: Basic Tool Usage
defmodule Example1 do
  def run do
    IO.puts("=== Example 1: Basic Tool Usage ===\n")

    {:ok, client} = McpClient.start_link(
      transport: :stdio,
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-everything"]
    )

    # List tools
    {:ok, %{"tools" => tools}} = McpClient.list_tools(client)
    IO.puts("Available tools: #{length(tools)}")

    for tool <- tools do
      IO.puts("  - #{tool["name"]}: #{tool["description"]}")
    end

    McpClient.stop(client)
  end
end

# Example 2: Resource Reading
defmodule Example2 do
  def run do
    IO.puts("\n=== Example 2: Resource Reading ===\n")

    {:ok, client} = McpClient.start_link(
      transport: :stdio,
      command: "your-resource-server"
    )

    {:ok, %{"resources" => resources}} = McpClient.list_resources(client)

    for resource <- resources do
      {:ok, content} = McpClient.read_resource(client, resource["uri"])
      IO.puts("Resource: #{resource["uri"]}")
      IO.inspect(content)
    end

    McpClient.stop(client)
  end
end

# Example 3: Notification Handling
defmodule Example3 do
  def run do
    IO.puts("\n=== Example 3: Notification Handling ===\n")

    handler = fn notification ->
      IO.puts("Received notification: #{notification.method}")
      IO.inspect(notification.params)
    end

    {:ok, client} = McpClient.start_link(
      transport: :stdio,
      command: "your-server",
      notification_handlers: [handler]
    )

    # Do work...
    Process.sleep(5000)

    McpClient.stop(client)
  end
end

# Run examples
# Example1.run()
# Example2.run()
# Example3.run()
```

---

### 3. Configuration Guide

**File: `guides/configuration.md`**

```markdown
# Configuration Guide

Complete reference for all McpClient configuration options.

## Transport Configuration

### Stdio Transport

```elixir
transport: :stdio,
command: "executable",
args: ["arg1", "arg2"],
env: [{"VAR", "value"}]
```

**command** (required)
- Path to executable or command name
- Must be in PATH or absolute path
- Example: `"npx"`, `"python"`, `"/usr/local/bin/server"`

**args** (optional, default: [])
- List of command arguments
- Example: `["-y", "@modelcontextprotocol/server-everything"]`

**env** (optional, default: [])
- Environment variables for subprocess
- List of tuples: `[{"VAR_NAME", "value"}]`
- Example: `[{"DEBUG", "true"}, {"API_KEY", key}]`

## Timeout Configuration

### request_timeout

Default request timeout for all operations.

```elixir
request_timeout: 30_000  # 30 seconds (default)
```

Can be overridden per-request:

```elixir
McpClient.call_tool(client, "tool", %{}, timeout: 60_000)
```

### init_timeout

Timeout for initialize handshake with server.

```elixir
init_timeout: 10_000  # 10 seconds (default)
```

Increase if server is slow to start:

```elixir
init_timeout: 30_000  # 30 seconds
```

## Reconnection Configuration

### backoff_min

Minimum delay before reconnection attempt.

```elixir
backoff_min: 1_000  # 1 second (default)
```

### backoff_max

Maximum delay before reconnection attempt.

```elixir
backoff_max: 30_000  # 30 seconds (default)
```

**Backoff progression:**
- 1st reconnect: backoff_min (1s)
- 2nd reconnect: 2s
- 3rd reconnect: 4s
- 4th reconnect: 8s
- 5th reconnect: 16s
- 6th reconnect: 30s (capped at backoff_max)

## Retry Configuration

### retry_attempts

Maximum send attempts when transport is busy.

```elixir
retry_attempts: 3  # Default (initial + 2 retries)
```

### retry_delay_ms

Base delay between retry attempts.

```elixir
retry_delay_ms: 10  # 10ms (default)
```

### retry_jitter

Jitter factor for retry delays (prevents thundering herd).

```elixir
retry_jitter: 0.5  # ±50% (default)
```

With default config, retry delays are:
- Range: [5ms, 15ms]
- Randomized per retry

## Advanced Configuration

### max_frame_bytes

Maximum allowed frame size (DoS protection).

```elixir
max_frame_bytes: 16_777_216  # 16MB (default)
```

Frames exceeding this size trigger reconnection.

### tombstone_sweep_ms

Interval for cleaning up expired tombstones.

```elixir
tombstone_sweep_ms: 60_000  # 60 seconds (default)
```

Tombstones prevent duplicate responses. They expire after:
```
request_timeout + init_timeout + backoff_max + 5_000
= 75 seconds (default)
```

## Complete Example

```elixir
{:ok, client} = McpClient.start_link([
  # Transport
  transport: :stdio,
  command: "python",
  args: ["server.py"],
  env: [{"DEBUG", "true"}],

  # Timeouts (aggressive)
  request_timeout: 15_000,
  init_timeout: 5_000,

  # Reconnection (fast)
  backoff_min: 500,
  backoff_max: 10_000,

  # Retry (more attempts)
  retry_attempts: 5,
  retry_delay_ms: 20,
  retry_jitter: 0.3,

  # Handlers
  notification_handlers: [&MyApp.handle_notification/1]
])
```
```

---

## Success Criteria

**Must achieve:**
- ✅ README covers all MVP features
- ✅ All API functions documented
- ✅ Configuration guide complete
- ✅ Examples runnable and accurate
- ✅ Error handling explained
- ✅ Troubleshooting section included
- ✅ No references to non-MVP features
- ✅ Markdown renders correctly on GitHub/Hex

---

## Constraints

- **DO NOT** document features not in MVP (SSE, HTTP, cancellation, telemetry, pooling)
- **DO NOT** make promises about future features without marking as "Roadmap"
- All examples must be runnable
- All API signatures must match implementation
- All default values must match code

---

## Implementation Notes

### Documentation Testing

Use ExDoc's doctest feature for inline examples:

```elixir
@doc """
## Examples

    iex> {:ok, client} = McpClient.start_link(transport: :mock, command: "test")
    iex> is_pid(client)
    true
"""
```

### Hex.pm Requirements

For publishing to Hex, ensure:
- README.md in project root
- LICENSE file
- mix.exs has proper metadata
- Documentation builds with `mix docs`

### Versioning

Follow Semantic Versioning:
- v0.1.0 = MVP (stdio transport only)
- v0.2.0 = Add SSE transport
- v0.3.0 = Add HTTP transport
- v1.0.0 = Stable API

---

## Deliverable

Provide:
1. `README.md` - Complete project README
2. `examples/usage.exs` - Runnable examples
3. `guides/configuration.md` - Configuration guide
4. Update `mix.exs` - Add description, package metadata

All files must:
- Be accurate and match implementation
- Render correctly in Markdown
- Have no broken links
- Cover all MVP features
- Not reference non-MVP features

If any requirement is unclear, insert `# TODO: <reason>` and stop.
