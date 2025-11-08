# Transport Layer Specifications

**Date:** 2025-11-07
**Status:** Accepted
**Related:** ADR-0004 (Active-Once Backpressure), ADR-0008 (16MB Frame Limit)

## Overview

The MCP client supports three transport mechanisms for communicating with servers. Each transport implements the `McpClient.Transport` behavior and provides JSON-RPC 2.0 message exchange with flow control.

All transports share:
- **Active-once flow control** - Connection controls delivery via `set_active/2`
- **16MB frame size limit** - Oversized frames rejected
- **JSON-RPC 2.0 framing** - Newline-delimited JSON messages
- **Bidirectional communication** - Client can send, server can send
- **Plug-in friendly design** - Any module implementing `McpClient.Transport` can be injected via the `transport: {module(), opts}` option (see ADR-0014)

---

## Transport Behavior

All transports must implement this behavior:

```elixir
defmodule McpClient.Transport do
  @moduledoc """
  Behavior for MCP transport implementations.

  Transports handle the physical communication layer between client and server,
  delivering frames to the Connection process via messages.
  """

  @type frame :: binary()
  @type transport_pid :: pid()
  @type transport_opts :: Keyword.t()

  @doc """
  Start the transport process.

  Returns `{:ok, pid}` on success, `{:error, reason}` on failure.

  The transport should NOT start delivering frames until `set_active/2` is called.
  """
  @callback start_link(transport_opts()) :: {:ok, transport_pid()} | {:error, term()}

  @doc """
  Send a frame to the server.

  Returns:
  - `:ok` - Frame queued/sent successfully
  - `{:error, :busy}` - Transport buffer full, retry later
  - `{:error, :closed}` - Connection closed
  - `{:error, reason}` - Other error

  The caller (Connection) handles retry logic for `:busy` (see ADR-0007).
  """
  @callback send_frame(transport_pid(), frame()) ::
    :ok | {:error, :busy | :closed | term()}

  @doc """
  Control frame delivery to Connection.

  - `:once` - Deliver next frame, then pause
  - `false` - Stop delivering frames

  Returns `:ok` on success, `{:error, reason}` if transport closed/invalid.
  """
  @callback set_active(transport_pid(), :once | false) :: :ok | {:error, term()}

  @doc """
  Close the transport gracefully.

  Should flush pending writes if possible, then terminate.
  Returns `:ok` regardless of success (best-effort close).
  """
  @callback close(transport_pid()) :: :ok

  @doc """
  Get transport-specific information (optional).

  Returns map with transport details (e.g., PID, command, URL).
  Used for debugging and inspection.
  """
  @callback info(transport_pid()) :: map()
end
```

### Message Protocol

Transports send frames to Connection via messages:

```elixir
# Frame received from server
{:transport, :frame, binary()}

# Transport closed (connection lost, process died)
{:transport, :closed, reason :: term()}

# Transport error (non-fatal, transport still alive)
{:transport, :error, reason :: term()}
```

**Connection must:**
1. Process frame
2. Call `Transport.set_active(transport, :once)` to receive next frame
3. Handle `:closed` by transitioning to `:backoff` state
4. Log `:error` but continue operation

---

## Stdio Transport

**Purpose:** Communicate with local processes via standard input/output (most common for local MCP servers).

**Module:** `McpClient.Transports.Stdio`

### Architecture

```
┌──────────────────┐
│   Connection     │
│   (gen_statem)   │
└────────┬─────────┘
         │ {:transport, :frame, data}
         │ Transport.send_frame/2
         │ Transport.set_active/2
         ↓
┌──────────────────┐
│  Stdio Transport │
│   (GenServer)    │
└────────┬─────────┘
         │ Port.command/2
         │ {port, {:data, binary}}
         ↓
┌──────────────────┐
│   Erlang Port    │
│  (OS process)    │
└────────┬─────────┘
         │ stdin/stdout pipes
         ↓
┌──────────────────┐
│   MCP Server     │
│  (subprocess)    │
└──────────────────┘
```

### Configuration

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {
    McpClient.Transports.Stdio,
    cmd: "uvx",                          # Executable
    args: ["mcp-server-sqlite"],         # Arguments
    env: [{"DEBUG", "1"}],               # Environment variables
    cd: "/path/to/workdir"               # Working directory
  }
)
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `cmd` | `String.t()` | **required** | Executable command (e.g., "python", "node", "uvx") |
| `args` | `[String.t()]` | `[]` | Command arguments |
| `env` | `[{String.t(), String.t()}]` | `[]` | Environment variables (merge with system env) |
| `cd` | `String.t()` | `nil` | Working directory (default: current dir) |
| `stderr` | `:merge | :log` | `:merge` | Pipe stderr to stdout (`:merge`) or spawn Logger process (`:log`) |
| `max_frame_bytes` | `pos_integer()` | `16_777_216` | Max frame size (16MB) |
| `read_buffer_size` | `pos_integer()` | `65_536` | Read buffer size (64KB) |

### Implementation Details

**Port Configuration:**
```elixir
opts = [
  :binary,
  :exit_status,
  {:args, args},
  {:env, env},
  {:cd, cd}
]

opts =
  case stderr_mode do
    :merge -> [:stderr_to_stdout | opts]
    :log -> opts
  end

Port.open({:spawn_executable, executable}, opts)
```
We implement framing ourselves (no `:packet` modes) so we can support standard JSON-RPC `Content-Length` headers.

**Flow Control:**
- The Port still delivers messages to the transport GenServer, but the GenServer only reads header bytes while paused; body bytes remain unread, so the OS pipe applies backpressure.
- `set_active(:once)` flips the transport into “deliver next frame” mode: it finishes reading the declared body, enqueues the frame, and then pauses again.
- Connection must call `set_active(:once)` after handling a frame; `set_active_once_safe/1` no-ops in `:backoff`/`:closing`.

**Frame Format (JSON-RPC over stdio):**
```
Content-Length: <bytes>\r\n
\r\n
<JSON payload bytes>
```
- Header parsing stops at `\r\n\r\n`; we reject any declared length > `max_frame_bytes` before allocating the buffer.
- Example frame:
  ```
  Content-Length: 67\r\n
  \r\n
  {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
  ```
- Notification example (no `id`):
  ```
  Content-Length: 74\r\n
  \r\n
  {"jsonrpc":"2.0","method":"$/cancelRequest","params":{"requestId":123}}
  ```
- Request example (with `id`):
  ```
  Content-Length: <bytes>\r\n
  \r\n
  {"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"search","arguments":{"query":"TODO"}}}
  ```
  - Compute `Content-Length` from the UTF-8 byte size (`byte_size/1`).
  - Use string keys exactly as on the wire.
  - Notifications are identical frames without the `"id"` field (see above).
- Notifications are written with `Transport.send_frame/2` just like requests; JSON-RPC treats them as ordinary frames that simply omit the `id`.

**Subprocess Lifecycle:**
1. **Start:** Fork subprocess via Port
2. **Running:** Exchange Content-Length framed JSON payloads
3. **Close:** Send EOF to stdin, wait for exit
4. **Crash:** Port sends `{:EXIT, port, reason}`, transport notifies Connection

**Error Handling:**

| Error | Cause | Transport Action |
|-------|-------|------------------|
| Oversized frame | Line > max_frame_bytes | Send `{:transport, :error, :oversized_frame}`, close port |
| Subprocess exit | Process crashes | Send `{:transport, :closed, {:exit_status, code}}` |
| Port died | Port process crash | Send `{:transport, :closed, :port_terminated}` |
| Write failed | Broken pipe | Return `{:error, :closed}` from `send_frame/2` |

**send_frame/2 behavior:**
```elixir
def send_frame(transport, frame) do
  json = IO.iodata_to_binary(frame)
  byte_size(json) <= transport.max_frame_bytes || raise ArgumentError, "frame too large"
  header = ["Content-Length: ", Integer.to_string(byte_size(json)), "\r\n\r\n"]

  try do
    Port.command(port, [header, json])
    :ok
  catch
    :error, :badarg -> {:error, :closed}  # Port closed
  end
end
```

### Testing

**Unit tests:**
- Start/stop lifecycle
- Send/receive frames
- Oversized frame rejection
- Subprocess crash recovery
- Backpressure (active-once)

**Integration tests:**
- Real MCP servers (uvx mcp-server-*)
- Long messages (near 16MB)
- Burst traffic (many frames quickly)

**Example test:**
```elixir
test "stdio transport with echo server" do
  {:ok, transport} = Stdio.start_link(
    cmd: "cat",  # Echo stdin to stdout
    owner: self()
  )

  # Initially paused
  refute_receive {:transport, :frame, _}, 100

  # Enable delivery
  :ok = Stdio.set_active(transport, :once)

  # Send frame
  :ok = Stdio.send_frame(transport, ~s|{"test": 1}|)

  # Receive echo
  assert_receive {:transport, :frame, frame}, 1000
  assert Jason.decode!(frame) == %{"test" => 1}

  # Must re-enable for next frame
  refute_receive {:transport, :frame, _}, 100

  Stdio.close(transport)
end
```

---

## SSE Transport (Server-Sent Events)

**Purpose:** Receive server-initiated updates via HTTP SSE (unidirectional: server → client).

**Module:** `McpClient.Transports.SSE`

**Note:** SSE is **one-way only** (server → client). For bidirectional communication, use HTTP+SSE hybrid transport.

### Architecture

```
┌──────────────────┐
│   Connection     │
└────────┬─────────┘
         │ {:transport, :frame, data}
         ↓
┌──────────────────┐
│  SSE Transport   │
│   (Task-based)   │
└────────┬─────────┘
         │ HTTP GET with Accept: text/event-stream
         ↓
┌──────────────────┐
│   HTTP Client    │
│   (Req/Finch)    │
└────────┬─────────┘
         │ Streaming connection
         ↓
┌──────────────────┐
│   MCP Server     │
│   (HTTP/SSE)     │
└──────────────────┘
```

### Configuration

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {
    McpClient.Transports.SSE,
    url: "https://mcp.example.com/sse",
    headers: [{"authorization", "Bearer #{token}"}]
  }
)
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `url` | `String.t()` | **required** | SSE endpoint URL |
| `headers` | `[{String.t(), String.t()}]` | `[]` | HTTP headers (auth, etc.) |
| `max_frame_bytes` | `pos_integer()` | `16_777_216` | Max event data size |
| `reconnect_delay` | `pos_integer()` | `5_000` | Delay before reconnect on disconnect |

### Implementation Details

**SSE Protocol:**
- HTTP GET with `Accept: text/event-stream`
- Server sends events:
  ```
  event: message
  data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{...}}

  ```
- Events delimited by double newline
- Client maintains long-lived connection

**Frame Extraction:**
```elixir
# SSE event format:
# event: message
# data: <JSON-RPC message>
#
# (blank line)

# Extract data field, deliver as frame
def parse_sse_event(event) do
  event
  |> String.split("\n")
  |> Enum.find_value(fn line ->
    case String.split(line, ": ", parts: 2) do
      ["data", data] -> data
      _ -> nil
    end
  end)
end
```

**Flow Control:**
- SSE stream is continuous
- Transport buffers events internally
- Delivers one event per `set_active(:once)`
- Pauses buffering when buffer full (backpressure)

**Reconnection:**
- If connection drops, wait `reconnect_delay`ms
- Reconnect automatically (send `Last-Event-ID` header if server supports)
- Notify Connection via `{:transport, :closed, :reconnecting}`

**send_frame/2 behavior:**
```elixir
def send_frame(_transport, _frame) do
  # SSE is server → client only
  {:error, :send_not_supported}
end
```

**Limitations:**
- ⚠️ **One-way only** - Cannot send requests to server
- ⚠️ Must use HTTP+SSE hybrid for bidirectional communication

### Use Cases

**Appropriate:**
- Receiving notifications from cloud MCP servers
- Read-only dashboards
- Subscription-based data feeds

**Not appropriate:**
- Interactive tool execution (need bidirectional)
- Request/response operations (need client → server)

---

## HTTP+SSE Transport (Bidirectional)

**Purpose:** Full bidirectional communication via HTTP POST (client → server) + SSE (server → client).

**Module:** `McpClient.Transports.HTTP`

### Architecture

```
┌──────────────────┐
│   Connection     │
└─────┬────────┬───┘
      │        │ {:transport, :frame, data}
      │        ↓
      │   ┌──────────────────┐
      │   │   SSE Stream     │
      │   │   (Task)         │
      │   └──────────────────┘
      │        ↓
      │   GET /sse
      ↓
┌──────────────────┐
│  POST Endpoint   │
│   (send_frame)   │
└──────────────────┘
      │
      ↓ POST /messages
┌──────────────────┐
│   MCP Server     │
│   (HTTP+SSE)     │
└──────────────────┘
```

### Configuration

```elixir
{:ok, conn} = McpClient.start_link(
  transport: {
    McpClient.Transports.HTTP,
    base_url: "https://mcp.example.com",
    sse_path: "/sse",
    message_path: "/messages",
    headers: [{"authorization", "Bearer #{token}"}],
    oauth: %{
      client_id: "...",
      client_secret: "...",
      token_url: "https://auth.example.com/token"
    }
  }
)
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `base_url` | `String.t()` | **required** | Base URL (e.g., "https://api.example.com") |
| `sse_path` | `String.t()` | `"/sse"` | SSE endpoint path |
| `message_path` | `String.t()` | `"/messages"` | POST message endpoint path |
| `headers` | `[{String.t(), String.t()}]` | `[]` | HTTP headers for all requests |
| `oauth` | `map()` | `nil` | OAuth 2.1 configuration (see below) |
| `max_frame_bytes` | `pos_integer()` | `16_777_216` | Max frame size |
| `timeout` | `pos_integer()` | `30_000` | HTTP request timeout |

### Implementation Details

**Two-Channel Design:**

1. **SSE Channel (server → client):**
   - Long-lived GET request to `base_url <> sse_path`
   - Receives notifications, responses
   - Automatically reconnects on disconnect

2. **POST Channel (client → server):**
   - POST to `base_url <> message_path` for each request
   - Body: JSON-RPC 2.0 message
   - Response: HTTP 200 (acknowledgment only, actual response via SSE)

**Request/Response Flow:**
```
Client                          Server
  │                               │
  ├──── POST /messages ───────────>│
  │     {"jsonrpc":"2.0","id":1,   │
  │      "method":"tools/list"}    │
  │                               │
  │<──── HTTP 200 OK ─────────────┤
  │     (empty body)               │
  │                               │
  │     SSE /sse stream            │
  │<──── event: message ───────────┤
  │     data: {"jsonrpc":"2.0",    │
  │            "id":1,              │
  │            "result":{...}}     │
```

**send_frame/2 behavior:**
```elixir
def send_frame(transport, frame) do
  case HTTP.post(message_url, frame, headers, timeout: 30_000) do
    {:ok, %{status: 200}} -> :ok
    {:ok, %{status: 429}} -> {:error, :busy}      # Rate limited
    {:ok, %{status: 503}} -> {:error, :busy}      # Service unavailable
    {:error, reason} -> {:error, reason}
  end
end
```

### OAuth 2.1 Support

**Configuration:**
```elixir
oauth: %{
  client_id: "your-client-id",
  client_secret: "your-client-secret",
  token_url: "https://auth.example.com/oauth/token",
  scope: "mcp:read mcp:write",
  refresh_threshold: 300  # Refresh 5 minutes before expiry
}
```

**Token Management:**
- Transport obtains token via OAuth 2.1 client credentials flow
- Automatically includes `Authorization: Bearer <token>` header
- Refreshes token when within `refresh_threshold` seconds of expiry
- Handles token errors by requesting new token

**Flow:**
```elixir
# Initial token request
POST /oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&
client_id=...&
client_secret=...&
scope=mcp:read mcp:write

# Response
{
  "access_token": "...",
  "token_type": "Bearer",
  "expires_in": 3600
}

# Use token in all requests
Authorization: Bearer <access_token>
```

**Deferred to Post-MVP:**
- Authorization code flow (requires user interaction)
- Refresh token rotation
- Multiple OAuth providers
- PKCE extension

### Testing

**Unit tests:**
- Token acquisition and refresh
- POST message sending
- SSE event parsing
- Reconnection logic

**Integration tests:**
- Real OAuth provider
- Rate limiting (429 responses)
- Network interruption recovery

---

## Transport Comparison

| Feature | Stdio | SSE | HTTP+SSE |
|---------|-------|-----|----------|
| **Direction** | Bidirectional | Server → Client | Bidirectional |
| **Use Case** | Local servers | Notifications only | Cloud/remote servers |
| **Authentication** | Process isolation | HTTP headers/cookies | OAuth 2.1 |
| **Reliability** | Process crash = fail | Auto-reconnect | Auto-reconnect |
| **Performance** | Lowest latency | Medium latency | Higher latency (2x HTTP) |
| **Complexity** | Low | Medium | High |
| **MVP Status** | ✅ Included | ✅ Included | ✅ Included |

### Choosing a Transport

**Use Stdio when:**
- Server is local executable (Python, Node, Rust binary)
- Low latency required
- Process isolation is security boundary
- Examples: mcp-server-sqlite, mcp-server-filesystem

**Use SSE when:**
- Only receiving notifications (no requests)
- Cloud-based notification feed
- Read-only dashboard
- Examples: Monitoring feeds, log tails

**Use HTTP+SSE when:**
- Server is remote/cloud
- Need request/response + notifications
- OAuth authentication required
- Examples: Enterprise MCP services, hosted AI tools

---

## Common Transport Features

### Frame Size Protection

All transports enforce 16MB frame limit (see ADR-0008):

```elixir
def validate_frame_size(frame) when byte_size(frame) > 16_777_216 do
  {:error, :oversized_frame}
end
def validate_frame_size(frame), do: {:ok, frame}
```

**On violation:**
1. Log error with frame size
2. Send `{:transport, :error, :oversized_frame}` to Connection
3. Close transport immediately
4. Connection transitions to `:backoff` state

### Active-Once Flow Control

All transports implement the same pattern:

```elixir
defmodule TransportState do
  defstruct [
    :owner,           # Connection pid
    :active,          # false | :once
    :buffer,          # Queue of pending frames
    # ... transport-specific fields
  ]
end

def handle_info({:frame_received, frame}, state) do
  case state.active do
    :once ->
      # Deliver frame to owner
      send(state.owner, {:transport, :frame, frame})
      # Reset to paused
      {:noreply, %{state | active: false}}

    false ->
      # Buffer frame for later
      buffer = :queue.in(frame, state.buffer)
      {:noreply, %{state | buffer: buffer}}
  end
end

def set_active(transport, mode) do
  GenServer.call(transport, {:set_active, mode})
end

def handle_call({:set_active, :once}, _from, state) do
  case :queue.out(state.buffer) do
    {{:value, frame}, buffer} ->
      # Deliver buffered frame immediately
      send(state.owner, {:transport, :frame, frame})
      {:reply, :ok, %{state | active: false, buffer: buffer}}

    {:empty, _} ->
      # No buffered frames, enable delivery
      {:reply, :ok, %{state | active: :once}}
  end
end
```

### Error Reporting

All transports use consistent error reporting:

**To Connection:**
```elixir
# Non-fatal error (transport still alive)
send(owner, {:transport, :error, reason})

# Fatal error (transport closing)
send(owner, {:transport, :closed, reason})
```

**From send_frame/2:**
```elixir
:ok                      # Success
{:error, :busy}          # Temporary failure, retry
{:error, :closed}        # Transport closed, fail request
{:error, other}          # Other error, fail request
```

### Graceful Shutdown

All transports implement graceful close:

```elixir
def close(transport) do
  GenServer.call(transport, :close, 5000)
end

def handle_call(:close, _from, state) do
  # 1. Stop accepting new frames
  state = %{state | active: false}

  # 2. Flush pending writes (best-effort)
  flush_pending_writes(state)

  # 3. Close underlying connection
  close_connection(state)

  # 4. Notify owner
  send(state.owner, {:transport, :closed, :normal})

  {:stop, :normal, :ok, state}
end
```

---

## Supervision

Transports are supervised by `rest_for_one` strategy (see ADR-0002):

```elixir
children = [
  {Transport, transport_opts},  # Supervised
  {Connection, connection_opts}  # Restarted if Transport dies
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

**If Transport crashes:**
1. Supervisor restarts Transport
2. Supervisor restarts Connection (rest_for_one)
3. Connection re-initializes with new Transport

**If Connection crashes:**
1. Supervisor restarts Connection
2. Transport remains running
3. Connection reconnects to existing Transport

---

## Testing Transports

### Unit Test Requirements

Each transport must have:

1. **Lifecycle tests:**
   - Start/stop
   - Normal close
   - Crash recovery

2. **Flow control tests:**
   - set_active(:once) enables delivery
   - set_active(false) pauses delivery
   - Buffering when paused
   - Multiple frames queued

3. **Frame tests:**
   - Send valid frame
   - Receive valid frame
   - Oversized frame rejection
   - Invalid JSON handling

4. **Error tests:**
   - Connection loss
   - Write failure
   - Read failure
   - Timeout

### Integration Test Requirements

1. **Real server tests:**
   - Connect to actual MCP server
   - Send/receive multiple frames
   - Handle disconnect/reconnect

2. **Stress tests:**
   - High frame rate (1000+ frames/sec)
   - Large frames (near 16MB)
   - Sustained load (hours)

3. **Network tests** (HTTP only):
   - Slow network (high latency)
   - Packet loss
   - Reconnection storms

---

## References

- **ADR-0004**: Active-Once Backpressure Model
- **ADR-0008**: 16MB Maximum Frame Size Limit
- **MCP Specification**: https://spec.modelcontextprotocol.io/specification/basic/transports/
- **JSON-RPC 2.0**: https://www.jsonrpc.org/specification
- **SSE Specification**: https://html.spec.whatwg.org/multipage/server-sent-events.html
- **OAuth 2.1**: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-10

---

**Status**: Ready for implementation (stdio in PROMPT_06, SSE/HTTP post-MVP)
**Next**: Implement stdio transport first, defer SSE/HTTP to post-MVP phases
- **stderr handling:** In `:merge` mode we set `:stderr_to_stdout` so server logs arrive as frames tagged `{:transport, :stderr, binary}`; in `:log` mode a dedicated Logger task drains stderr to avoid back-pressure.
