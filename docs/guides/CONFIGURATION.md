# Configuration Guide

Complete reference for configuring MCP Client connections.

---

## Overview

MCP Client connections are configured via `start_link/1` options. This guide covers all configuration options, defaults, and best practices.

---

## Basic Configuration

Minimal configuration requires only a transport:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mcp-server"}
)
```

With common options:

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mcp-server"},
  name: MyApp.MCPConnection,
  request_timeout: 30_000,
  notification_handler: &MyApp.handle_notification/1
)
```

---

## Connection Options

### Transport Configuration

**Required.** Specifies the transport layer and its options.

```elixir
transport: {module(), Keyword.t()}
```

**Examples:**

```elixir
# Stdio (local process)
transport: {McpClient.Transports.Stdio,
            cmd: "uvx",
            args: ["mcp-server-sqlite", "--db-path", "./data.db"]}

# SSE (server-sent events, receive only)
transport: {McpClient.Transports.SSE,
            url: "https://api.example.com/sse",
            headers: [{"authorization", "Bearer token"}]}

# HTTP+SSE (bidirectional)
transport: {McpClient.Transports.HTTP,
            base_url: "https://api.example.com",
            oauth: %{client_id: "...", client_secret: "..."}}
```

See [Transport Configuration](#transport-configuration) section for transport-specific options.

### Process Options

**`name`** - Register connection with a name

```elixir
name: MyApp.MCPConnection  # atom
name: {:via, Registry, {MyApp.Registry, "mcp-conn"}}  # via tuple
```

Default: None (connection is not registered)

**When to use:**
- Supervised connections that need to be accessed globally
- Single connection per application
- Connection needs to be discoverable by name

**Example:**

```elixir
# Start named connection
{:ok, _conn} = McpClient.start_link(
  name: MyApp.MCPConnection,
  transport: {...}
)

# Access anywhere in application
conn = Process.whereis(MyApp.MCPConnection)
McpClient.Tools.list(conn)
```

> **Note:** Registry-backed names (`{:via, Registry, {MyApp.MCP.Registry, key}}`) are the recommended default. They allow multiple connections per server without singletons and fulfill the registry requirement introduced in ADR-0012.

### Stateless Supervisor Override

**`stateless_supervisor`** - Replace the default `Task.Supervisor` that executes `:stateless` tools.

```elixir
stateless_supervisor: {MyApp.StatelessSupervisor, strategy: :one_for_one}
```

Default: `McpClient.StatelessSupervisor` (started alongside each connection).

**When to use:**
- Route stateless executions through an existing supervision tree
- Change restart intensity or partition workloads per tenancy

### Timeout Options

**`request_timeout`** - Maximum time for request/response

```elixir
request_timeout: 30_000  # milliseconds (default)
```

Default: `30_000` (30 seconds)

Applies to:
- Tool calls
- Resource reads
- Prompt requests
- Any request/response operation

**When to increase:**
- Long-running tool executions
- Large resource downloads
- Slow server responses

**Example:**

```elixir
# Global timeout
{:ok, conn} = McpClient.start_link(
  transport: {...},
  request_timeout: 60_000  # 60 seconds
)

# Per-request override
{:ok, result} = McpClient.Tools.call(conn, "slow_tool", %{}, timeout: 120_000)
```

**`init_timeout`** - Time allowed for initialize handshake

```elixir
init_timeout: 10_000  # milliseconds (default)
```

Default: `10_000` (10 seconds)

**When to increase:**
- Slow server startup
- Complex capability negotiation
- Remote servers with high latency

### Backoff/Reconnection Options

**`backoff_min`** - Minimum reconnection delay

```elixir
backoff_min: 1_000  # milliseconds (default)
```

Default: `1_000` (1 second)

**`backoff_max`** - Maximum reconnection delay

```elixir
backoff_max: 30_000  # milliseconds (default)
```

Default: `30_000` (30 seconds)

**`backoff_jitter`** - Randomization factor for backoff

```elixir
backoff_jitter: 0.2  # 0.0 to 1.0 (default: 0.2)
```

Default: `0.2` (±20% randomization)

**How backoff works:**
1. First reconnect: `backoff_min` (1s)
2. Second reconnect: 2s (doubled)
3. Third reconnect: 4s (doubled)
4. Fourth reconnect: 8s (doubled)
5. Continues doubling until `backoff_max` (30s)
6. Jitter adds randomness: `delay * (1 ± jitter)`

**Example - Aggressive reconnection:**

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  backoff_min: 100,      # Start at 100ms
  backoff_max: 5_000,    # Max 5 seconds
  backoff_jitter: 0.1    # Less randomness
)
```

**Example - Conservative reconnection:**

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  backoff_min: 5_000,    # Start at 5 seconds
  backoff_max: 300_000,  # Max 5 minutes
  backoff_jitter: 0.5    # More randomness
)
```

### Reliability Options

**`retry_attempts`** - Max send retries when transport busy

```elixir
retry_attempts: 3  # default
```

Default: `3`

When transport returns `:busy`, connection will retry up to this many times.

**`retry_delay_ms`** - Base delay between send retries

```elixir
retry_delay_ms: 10  # milliseconds (default)
```

Default: `10` (10 milliseconds)

**`retry_jitter`** - Jitter for retry delays

```elixir
retry_jitter: 0.5  # 0.0 to 1.0 (default: 0.5)
```

Default: `0.5` (±50% randomization)

**`tombstone_sweep_ms`** - Interval for cleaning old request tombstones

```elixir
tombstone_sweep_ms: 60_000  # milliseconds (default)
```

Default: `60_000` (60 seconds)

Tombstones prevent late responses from being delivered after timeout/cancel. They're automatically cleaned up every `tombstone_sweep_ms`.

**`max_frame_bytes`** - Maximum incoming frame size

```elixir
max_frame_bytes: 16_777_216  # bytes (default: 16MB)
```

Default: `16_777_216` (16MB)

Frames larger than this are rejected and connection is closed. Protects against memory exhaustion.

### Notification Handling

**`notification_handler`** - Callback for server-initiated notifications

```elixir
notification_handler: (map() -> :ok)
```

Default: `nil` (notifications are ignored)

**Function signature:**

```elixir
@spec notification_handler(notification :: map()) :: :ok
```

**Example:**

```elixir
defmodule MyApp.NotificationHandler do
  require Logger

  def handle(notification) do
    case McpClient.NotificationRouter.route(notification) do
      {:resources, :updated, %{"uri" => uri}} ->
        Logger.info("Resource updated: #{uri}")
        MyApp.Cache.invalidate(uri)

      {:tools, :list_changed, _} ->
        Logger.info("Tools changed")
        Task.start(fn -> MyApp.refresh_tools() end)

      {:logging, :message, %{"level" => level, "data" => data}} ->
        Logger.log(String.to_existing_atom(level), "[MCP] #{inspect(data)}")

      {:progress, %{"progressToken" => token, "progress" => p}} ->
        MyApp.ProgressTracker.update(token, p)

      {:unknown, notif} ->
        Logger.debug("Unknown notification: #{inspect(notif)}")

      _ -> :ok
    end

    :ok
  end
end

# Configure
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: &MyApp.NotificationHandler.handle/1
)
```

**Important:**
- Handlers are called **synchronously** in connection process
- Keep handlers fast (< 1ms) to avoid blocking connection
- Offload work to tasks/processes for slow operations
- Always return `:ok`

### Capability Options

**`client_capabilities`** - Capabilities exposed by client

```elixir
client_capabilities: map()
```

Default:
```elixir
%{
  "roots" => %{
    "listChanged" => true
  }
}
```

**Custom capabilities:**

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  client_capabilities: %{
    "roots" => %{"listChanged" => true},
    "sampling" => %{},  # Client can perform sampling
    "experimental" => %{
      "myCustomFeature" => %{"version" => "1.0"}
    }
  }
)
```

**`roots`** - Filesystem roots exposed to server

```elixir
roots: [%{uri: String.t(), name: String.t()}]
```

Default: `[]` (no roots)

**Example:**

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  roots: [
    %{uri: "file:///home/user/project", name: "Project"},
    %{uri: "file:///home/user/documents", name: "Documents"}
  ]
)
```

Server can query these roots and access files within them.

---

## Transport Configuration

### Stdio Transport

**Purpose:** Local MCP servers (executables, scripts)

**Options:**

```elixir
{McpClient.Transports.Stdio, [
  cmd: String.t(),                           # Required
  args: [String.t()],                        # Default: []
  env: [{String.t(), String.t()}],           # Default: []
  cd: String.t(),                            # Default: nil (current dir)
  max_frame_bytes: pos_integer(),            # Default: 16MB
  read_buffer_size: pos_integer()            # Default: 64KB
]}
```

**Examples:**

```elixir
# Python server
transport: {McpClient.Transports.Stdio,
            cmd: "python",
            args: ["server.py"],
            env: [{"DEBUG", "1"}],
            cd: "/path/to/server"}

# Node.js server
transport: {McpClient.Transports.Stdio,
            cmd: "node",
            args: ["dist/index.js", "--port", "3000"]}

# uvx (Python tool runner)
transport: {McpClient.Transports.Stdio,
            cmd: "uvx",
            args: ["mcp-server-sqlite", "--db-path", "./data.db"]}

# Rust binary
transport: {McpClient.Transports.Stdio,
            cmd: "/usr/local/bin/mcp-server-rust"}
```

**Environment variables:**

```elixir
transport: {McpClient.Transports.Stdio,
            cmd: "mcp-server",
            env: [
              {"MCP_LOG_LEVEL", "debug"},
              {"DATABASE_URL", "sqlite://data.db"},
              {"API_KEY", System.get_env("API_KEY")}
            ]}
```

**Working directory:**

```elixir
transport: {McpClient.Transports.Stdio,
            cmd: "python",
            args: ["server.py"],
            cd: "/home/user/mcp-servers/my-server"}
```

### SSE Transport

**Purpose:** Server-sent events (receive notifications only, no requests)

**Options:**

```elixir
{McpClient.Transports.SSE, [
  url: String.t(),                           # Required
  headers: [{String.t(), String.t()}],       # Default: []
  max_frame_bytes: pos_integer(),            # Default: 16MB
  reconnect_delay: pos_integer()             # Default: 5000ms
]}
```

**Examples:**

```elixir
# Basic SSE
transport: {McpClient.Transports.SSE,
            url: "https://mcp.example.com/events"}

# With authentication
transport: {McpClient.Transports.SSE,
            url: "https://mcp.example.com/events",
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-client-id", "my-app"}
            ]}

# Custom reconnect delay
transport: {McpClient.Transports.SSE,
            url: "https://mcp.example.com/events",
            reconnect_delay: 10_000}  # 10 seconds
```

**Limitations:**
- ⚠️ **Receive only** - Cannot send requests to server
- ⚠️ Use HTTP+SSE transport for bidirectional communication

### HTTP+SSE Transport

**Purpose:** Bidirectional communication with cloud/remote servers

**Options:**

```elixir
{McpClient.Transports.HTTP, [
  base_url: String.t(),                      # Required
  sse_path: String.t(),                      # Default: "/sse"
  message_path: String.t(),                  # Default: "/messages"
  headers: [{String.t(), String.t()}],       # Default: []
  oauth: map(),                              # Default: nil
  max_frame_bytes: pos_integer(),            # Default: 16MB
  timeout: pos_integer()                     # Default: 30000ms
]}
```

**Examples:**

```elixir
# Basic HTTP+SSE
transport: {McpClient.Transports.HTTP,
            base_url: "https://mcp.example.com"}

# Custom paths
transport: {McpClient.Transports.HTTP,
            base_url: "https://mcp.example.com",
            sse_path: "/api/v1/sse",
            message_path: "/api/v1/messages"}

# With static auth headers
transport: {McpClient.Transports.HTTP,
            base_url: "https://mcp.example.com",
            headers: [
              {"authorization", "Bearer #{static_token}"},
              {"x-api-version", "2024-11-05"}
            ]}

# With OAuth 2.1
transport: {McpClient.Transports.HTTP,
            base_url: "https://mcp.example.com",
            oauth: %{
              client_id: System.get_env("MCP_CLIENT_ID"),
              client_secret: System.get_env("MCP_CLIENT_SECRET"),
              token_url: "https://auth.example.com/oauth/token",
              scope: "mcp:read mcp:write",
              refresh_threshold: 300  # Refresh 5 min before expiry
            }}
```

**OAuth configuration:**

```elixir
oauth: %{
  client_id: String.t(),           # Required
  client_secret: String.t(),       # Required
  token_url: String.t(),           # Required
  scope: String.t(),               # Optional (default: "")
  refresh_threshold: integer()     # Optional (default: 300 seconds)
}
```

The transport will:
1. Obtain access token via OAuth 2.1 client credentials flow
2. Add `Authorization: Bearer <token>` to all requests
3. Automatically refresh token before expiry

---

## Configuration Patterns

### Development vs Production

**Development** (fast feedback, verbose):

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio,
              cmd: "python",
              args: ["server.py"],
              env: [{"DEBUG", "1"}]},
  request_timeout: 5_000,      # Short timeout (fail fast)
  backoff_min: 100,             # Quick reconnects
  backoff_max: 5_000,
  notification_handler: fn notif ->
    IO.inspect(notif, label: "MCP Notification")
    :ok
  end
)
```

**Production** (resilient, conservative):

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.HTTP,
              base_url: System.get_env("MCP_SERVER_URL"),
              oauth: %{
                client_id: System.get_env("MCP_CLIENT_ID"),
                client_secret: System.get_env("MCP_CLIENT_SECRET"),
                token_url: System.get_env("MCP_TOKEN_URL")
              }},
  request_timeout: 60_000,     # Longer timeout (graceful)
  backoff_min: 5_000,           # Conservative reconnects
  backoff_max: 300_000,         # Max 5 minutes
  notification_handler: &MyApp.NotificationHandler.handle/1,
  name: MyApp.MCPConnection
)
```

### Supervised Configuration

Add to application supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    mcp_config = Application.get_env(:my_app, :mcp_client)

    children = [
      {McpClient, [
        name: MyApp.MCPConnection,
        transport: mcp_config[:transport],
        request_timeout: mcp_config[:request_timeout],
        notification_handler: &MyApp.NotificationHandler.handle/1
      ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**config/runtime.exs:**

```elixir
import Config

config :my_app, :mcp_client,
  transport: {
    McpClient.Transports.Stdio,
    cmd: System.get_env("MCP_SERVER_CMD", "mcp-server"),
    args: String.split(System.get_env("MCP_SERVER_ARGS", ""), " ")
  },
  request_timeout: String.to_integer(System.get_env("MCP_TIMEOUT", "30000"))
```

### Multiple Connections

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # SQLite database
      {McpClient, [
        name: MyApp.DatabaseConnection,
        transport: {McpClient.Transports.Stdio,
                    cmd: "uvx",
                    args: ["mcp-server-sqlite", "--db-path", "./data.db"]}
      ]},

      # Filesystem
      {McpClient, [
        name: MyApp.FilesystemConnection,
        transport: {McpClient.Transports.Stdio,
                    cmd: "uvx",
                    args: ["mcp-server-filesystem", "./files"]}
      ]},

      # Cloud API
      {McpClient, [
        name: MyApp.CloudConnection,
        transport: {McpClient.Transports.HTTP,
                    base_url: "https://mcp.example.com",
                    oauth: get_oauth_config()}
      ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp get_oauth_config do
    %{
      client_id: System.get_env("CLOUD_CLIENT_ID"),
      client_secret: System.get_env("CLOUD_CLIENT_SECRET"),
      token_url: "https://auth.example.com/oauth/token"
    }
  end
end
```

Access connections:

```elixir
# Database tools
{:ok, tools} = McpClient.Tools.list(MyApp.DatabaseConnection)

# Filesystem resources
{:ok, resources} = McpClient.Resources.list(MyApp.FilesystemConnection)

# Cloud prompts
{:ok, prompts} = McpClient.Prompts.list(MyApp.CloudConnection)
```

---

## Performance Tuning

### Timeout Tuning

**Symptom:** Frequent timeout errors

**Solutions:**

```elixir
# Increase global timeout
request_timeout: 60_000  # 60 seconds

# Or use per-request timeouts
McpClient.Tools.call(conn, "slow_tool", %{}, timeout: 120_000)
```

**Symptom:** Slow response times

**Solutions:**

```elixir
# Decrease timeout for fail-fast behavior
request_timeout: 5_000  # 5 seconds
```

### Reconnection Tuning

**Symptom:** Too many reconnection attempts

**Solutions:**

```elixir
# Less aggressive backoff
backoff_min: 5_000,      # Start at 5 seconds
backoff_max: 300_000     # Max 5 minutes
```

**Symptom:** Slow recovery after network issues

**Solutions:**

```elixir
# More aggressive backoff
backoff_min: 100,        # Start at 100ms
backoff_max: 5_000       # Max 5 seconds
```

### Frame Size Limits

**Symptom:** Large responses failing

**Solutions:**

```elixir
# Increase frame size limit (use cautiously!)
max_frame_bytes: 67_108_864  # 64MB

# In transport options
transport: {McpClient.Transports.Stdio,
            cmd: "mcp-server",
            max_frame_bytes: 67_108_864}
```

⚠️ **Warning:** Large frame sizes can cause memory exhaustion. Consider:
- Pagination at application level
- Streaming (post-MVP feature)
- Server-side chunking

---

## Security Configuration

### Credential Management

**Never hardcode credentials:**

```elixir
# ❌ Bad
transport: {McpClient.Transports.HTTP,
            base_url: "https://api.example.com",
            headers: [{"authorization", "Bearer hardcoded-token"}]}

# ✅ Good
transport: {McpClient.Transports.HTTP,
            base_url: System.get_env("MCP_API_URL"),
            oauth: %{
              client_id: System.get_env("MCP_CLIENT_ID"),
              client_secret: System.get_env("MCP_CLIENT_SECRET"),
              token_url: System.get_env("MCP_TOKEN_URL")
            }}
```

### Filesystem Roots

**Restrict server access:**

```elixir
# Only expose specific directories
{:ok, conn} = McpClient.start_link(
  transport: {...},
  roots: [
    %{uri: "file:///home/user/safe-directory", name: "Allowed"}
    # Server cannot access anything outside this
  ]
)
```

### Transport Security

**Use HTTPS for remote servers:**

```elixir
# ✅ Good
transport: {McpClient.Transports.HTTP,
            base_url: "https://mcp.example.com"}  # HTTPS

# ❌ Bad
transport: {McpClient.Transports.HTTP,
            base_url: "http://mcp.example.com"}  # HTTP (unencrypted)
```

---

## Debugging Configuration

### Enable verbose logging

```elixir
# In config/dev.exs
config :logger, :console,
  level: :debug,
  format: "[$level] $message\n"

# Inspect all notifications
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: fn notif ->
    IO.inspect(notif, label: "MCP Notification", pretty: true)
    :ok
  end
)
```

### Test configuration

```elixir
# In test/test_helper.exs
Application.put_env(:mcp_client, :test_mode, true)

# In tests
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mock-server"},
  request_timeout: 1_000,  # Short timeout for fast tests
  backoff_min: 10,          # Quick reconnect for tests
  backoff_max: 100
)
```

---

## Complete Example

Production-ready configuration:

```elixir
defmodule MyApp.MCP do
  @moduledoc "MCP client configuration and helpers"

  def child_spec do
    {McpClient, build_config()}
  end

  defp build_config do
    [
      name: __MODULE__.Connection,
      transport: build_transport(),
      request_timeout: timeout(),
      init_timeout: 10_000,
      backoff_min: backoff_min(),
      backoff_max: backoff_max(),
      backoff_jitter: 0.2,
      retry_attempts: 3,
      retry_delay_ms: 10,
      max_frame_bytes: max_frame_bytes(),
      notification_handler: &handle_notification/1,
      roots: roots()
    ]
  end

  defp build_transport do
    case transport_type() do
      :stdio ->
        {McpClient.Transports.Stdio,
         cmd: System.get_env("MCP_CMD", "mcp-server"),
         args: args(),
         env: env()}

      :http ->
        {McpClient.Transports.HTTP,
         base_url: System.fetch_env!("MCP_BASE_URL"),
         oauth: oauth_config()}
    end
  end

  defp transport_type do
    System.get_env("MCP_TRANSPORT", "stdio") |> String.to_atom()
  end

  defp args do
    System.get_env("MCP_ARGS", "") |> String.split(" ", trim: true)
  end

  defp env do
    System.get_env("MCP_ENV", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.map(fn [k, v] -> {k, v} end)
  end

  defp oauth_config do
    %{
      client_id: System.fetch_env!("MCP_CLIENT_ID"),
      client_secret: System.fetch_env!("MCP_CLIENT_SECRET"),
      token_url: System.fetch_env!("MCP_TOKEN_URL"),
      scope: System.get_env("MCP_SCOPE", "mcp:read mcp:write")
    }
  end

  defp timeout, do: String.to_integer(System.get_env("MCP_TIMEOUT", "30000"))
  defp backoff_min, do: String.to_integer(System.get_env("MCP_BACKOFF_MIN", "1000"))
  defp backoff_max, do: String.to_integer(System.get_env("MCP_BACKOFF_MAX", "30000"))
  defp max_frame_bytes, do: String.to_integer(System.get_env("MCP_MAX_FRAME", "16777216"))

  defp roots do
    System.get_env("MCP_ROOTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(fn path ->
      %{uri: "file://#{path}", name: Path.basename(path)}
    end)
  end

  defp handle_notification(notification) do
    MyApp.NotificationHandler.handle(notification)
  end

  # Helpers
  def conn, do: Process.whereis(__MODULE__.Connection)

  def call_tool(name, args, opts \\ []) do
    McpClient.Tools.call(conn(), name, args, opts)
  end

  def read_resource(uri, opts \\ []) do
    McpClient.Resources.read(conn(), uri, opts)
  end
end
```

**Environment variables:**

```bash
# .env
MCP_TRANSPORT=stdio
MCP_CMD=uvx
MCP_ARGS=mcp-server-sqlite --db-path ./data.db
MCP_TIMEOUT=60000
MCP_ROOTS=/home/user/project,/home/user/documents

# Or for HTTP
MCP_TRANSPORT=http
MCP_BASE_URL=https://mcp.example.com
MCP_CLIENT_ID=your-client-id
MCP_CLIENT_SECRET=your-client-secret
MCP_TOKEN_URL=https://auth.example.com/oauth/token
```

---

## References

- [Getting Started Guide](GETTING_STARTED.md) - Basic usage
- [Error Handling Guide](ERROR_HANDLING.md) - Error handling patterns
- [Advanced Patterns](ADVANCED_PATTERNS.md) - Production patterns
- [MVP Specification](../design/MVP_SPEC.md) - Complete technical specification
- [Transport Specifications](../design/TRANSPORT_SPECIFICATIONS.md) - Transport details

---

**Questions?** See [FAQ](FAQ.md) or open an issue on GitHub.
