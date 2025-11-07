# MCP Protocol Details

**Date:** 2025-11-07
**Status:** Accepted
**Protocol Version:** 2024-11-05
**Related:** MVP_SPEC.md, CLIENT_FEATURES.md

## Overview

The Model Context Protocol (MCP) is built on JSON-RPC 2.0 with specific message formats, capability negotiation, and lifecycle management. This document specifies the complete protocol details for implementing an MCP client.

**Example convention:** All JSON snippets use string keys exactly as they appear on the wire. Elixir code must convert atom keys back to string keys before encoding.

---

## JSON-RPC 2.0 Foundation

MCP uses JSON-RPC 2.0 for all communication.

### Request Format

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": {}
}
```

**Fields:**
- `jsonrpc`: Always `"2.0"` (string)
- `id`: Request correlation ID (number or string, unique per request)
- `method`: MCP method name (string)
- `params`: Method parameters (object or array, can be omitted if empty)

### Response Format (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [...]
  }
}
```

**Fields:**
- `jsonrpc`: Always `"2.0"`
- `id`: Matches request ID
- `result`: Method result (any JSON type)

### Response Format (Error)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found",
    "data": {"method": "unknown/method"}
  }
}
```

**Fields:**
- `jsonrpc`: Always `"2.0"`
- `id`: Matches request ID (or `null` if ID couldn't be determined)
- `error`: Error object with:
  - `code`: Integer error code (see Error Codes below)
  - `message`: Human-readable error description
  - `data`: Optional additional error details

### Notification Format

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "file:///path/to/file.txt"
  }
}
```

**No `id` field** - notifications are fire-and-forget, no response expected.

---

## Error Codes

MCP uses JSON-RPC 2.0 error codes plus custom codes:

### Standard JSON-RPC Errors

| Code | Meaning | Description |
|------|---------|-------------|
| `-32700` | Parse error | Invalid JSON |
| `-32600` | Invalid request | Missing required fields |
| `-32601` | Method not found | Unknown method name |
| `-32602` | Invalid params | Wrong parameter types/values |
| `-32603` | Internal error | Server internal error |

### MCP-Specific Errors

| Code | Meaning | When Used |
|------|---------|-----------|
| `-32001` | Resource not found | Resource URI doesn't exist |
| `-32002` | Resource not readable | Permission denied or I/O error |
| `-32003` | Tool not found | Tool name doesn't exist |
| `-32004` | Tool execution failed | Tool ran but returned error |
| `-32005` | Prompt not found | Prompt name doesn't exist |
| `-32006` | Sampling not supported | Server can't perform LLM sampling |
| `-32007` | Capability not supported | Client requested unsupported feature |

### Client Error Mapping

```elixir
defmodule McpClient.Error do
  def jsonrpc_code_to_type(code) do
    case code do
      -32700 -> :parse_error
      -32600 -> :invalid_request
      -32601 -> :method_not_found
      -32602 -> :invalid_params
      -32603 -> :internal_error
      -32001 -> :resource_not_found
      -32002 -> :resource_not_readable
      -32003 -> :tool_not_found
      -32004 -> :tool_execution_failed
      -32005 -> :prompt_not_found
      -32006 -> :sampling_not_supported
      -32007 -> :capability_not_supported
      _ -> :unknown_error
    end
  end

  def normalize_jsonrpc_error(%{"code" => code, "message" => message} = error) do
    %__MODULE__{
      type: jsonrpc_code_to_type(code),
      message: message,
      server_error: error,
      details: Map.get(error, "data", %{}),
      code: code
    }
  end
end
```

---

## Connection Lifecycle

### 1. Connection Establishment

Transport-specific connection (stdio process, SSE stream, HTTP handshake).

### 2. Initialize Handshake

**Client sends:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "roots": {
        "listChanged": true
      },
      "sampling": {}
    },
    "clientInfo": {
      "name": "elixir-mcp-client",
      "version": "0.1.0"
    }
  }
}
```

**Server responds:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "logging": {},
      "prompts": {
        "listChanged": true
      },
      "resources": {
        "subscribe": true,
        "listChanged": true
      },
      "tools": {
        "listChanged": true
      }
    },
    "serverInfo": {
      "name": "example-server",
      "version": "1.0.0"
    }
  }
}
```

**Fields:**

`initialize` request:
- `protocolVersion`: MCP protocol version (currently `"2024-11-05"`)
- `capabilities`: Client capabilities (see Capabilities section)
- `clientInfo`: Client identification
  - `name`: Client name
  - `version`: Client version

`initialize` result:
- `protocolVersion`: Server's protocol version (must match client)
- `capabilities`: Server capabilities
- `serverInfo`: Server identification
  - `name`: Server name
  - `version`: Server version

**Version policy:** MVP accepts only `"2024-11-05"`. Any other version transitions to `:backoff` with a protocol error; there is no YYYY-MM compatibility window.

### 3. Initialized Notification

**Client sends after successful initialize:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}
```

No `params` required. Signals client is ready.

### 4. Normal Operation

Client and server exchange requests, responses, and notifications.

### 5. Shutdown

**Client initiated:**
1. Stop sending new requests
2. Wait for in-flight responses (or timeout)
3. Close transport

**Server initiated:**
- Server closes transport (stdio EOF, SSE stream ends, HTTP disconnect)
- Client detects close, enters backoff/reconnect logic

**No explicit shutdown handshake** in MVP (deferred to post-MVP).

---

## Capabilities

Capabilities declare what features client/server support.

### Client Capabilities

```elixir
%{
  "roots" => %{
    "listChanged" => true  # Client can notify when roots change
  },
  "sampling" => %{}        # Client can perform sampling (rare)
}
```

**Client capabilities (MCP spec):**

| Capability | Sub-capability | Meaning |
|------------|----------------|---------|
| `roots` | - | Client exposes filesystem roots |
| `roots.listChanged` | - | Client sends `notifications/roots/list_changed` |
| `sampling` | - | Client can sample from LLMs (unusual) |

**MVP client capabilities:**
```elixir
@default_client_capabilities %{
  "roots" => %{
    "listChanged" => true
  }
}
```

### Server Capabilities

```elixir
%{
  "logging" => %{},
  "prompts" => %{
    "listChanged" => true
  },
  "resources" => %{
    "subscribe" => true,
    "listChanged" => true
  },
  "tools" => %{
    "listChanged" => true
  },
  "experimental" => %{
    "customFeature" => %{}
  }
}
```

**Server capabilities (MCP spec):**

| Capability | Sub-capability | Meaning |
|------------|----------------|---------|
| `logging` | - | Server supports logging (setLevel method) |
| `prompts` | - | Server exposes prompts |
| `prompts.listChanged` | - | Server sends `notifications/prompts/list_changed` |
| `resources` | - | Server exposes resources |
| `resources.subscribe` | - | Server supports resource subscriptions |
| `resources.listChanged` | - | Server sends `notifications/resources/list_changed` |
| `tools` | - | Server exposes tools |
| `tools.listChanged` | - | Server sends `notifications/tools/list_changed` |
| `experimental` | (any) | Custom extensions |

### Capability Negotiation

During `initialize`:
1. Client declares what it supports
2. Server declares what it supports
3. Both parties MUST only use mutually declared features
4. Client feature modules perform capability checks before issuing requests and return `{:error, %Error{type: :capability_not_supported}}` immediately if the server lacks the feature

**Example:**
- Client declares `roots.listChanged = true`
- Server declares `tools.listChanged = true`
- ✅ Client can send `notifications/roots/list_changed`
- ✅ Server can send `notifications/tools/list_changed`
- ❌ Client cannot use `resources/subscribe` (server didn't declare it)

**Validation in client:**
```elixir
def validate_server_capabilities(caps) do
  # Accept any valid capability structure
  # Don't require specific capabilities (server may have none)
  if is_map(caps), do: {:ok, caps}, else: {:error, :invalid_capabilities}
end

def server_supports?(capabilities, feature) do
  case get_in(capabilities, feature_path(feature)) do
    nil -> false
    _present -> true
  end
end

# Usage:
if server_supports?(server_caps, [:resources, :subscribe]) do
  McpClient.Resources.subscribe(conn, uri)
else
  {:error, :subscription_not_supported}
end
```

---

## Message Methods

Complete list of MCP methods by category:

### Initialization

| Method | Direction | Description |
|--------|-----------|-------------|
| `initialize` | Client → Server | Handshake with capabilities |
| `notifications/initialized` | Client → Server | Initialization complete |
| `ping` | Bidirectional | Heartbeat check |

### Tools

| Method | Direction | Description |
|--------|-----------|-------------|
| `tools/list` | Client → Server | List available tools |
| `tools/call` | Client → Server | Execute a tool |
| `notifications/tools/list_changed` | Server → Client | Tool list changed |

### Resources

| Method | Direction | Description |
|--------|-----------|-------------|
| `resources/list` | Client → Server | List available resources |
| `resources/read` | Client → Server | Read resource contents |
| `resources/templates/list` | Client → Server | List resource templates |
| `resources/subscribe` | Client → Server | Subscribe to resource updates |
| `resources/unsubscribe` | Client → Server | Unsubscribe from resource |
| `notifications/resources/updated` | Server → Client | Resource content changed |
| `notifications/resources/list_changed` | Server → Client | Resource list changed |

### Prompts

| Method | Direction | Description |
|--------|-----------|-------------|
| `prompts/list` | Client → Server | List available prompts |
| `prompts/get` | Client → Server | Get prompt with arguments |
| `notifications/prompts/list_changed` | Server → Client | Prompt list changed |

### Sampling

| Method | Direction | Description |
|--------|-----------|-------------|
| `sampling/createMessage` | Client → Server | Request LLM completion |

### Roots

| Method | Direction | Description |
|--------|-----------|-------------|
| `roots/list` | Server → Client | Request client's roots |
| `notifications/roots/list_changed` | Client → Server | Client roots changed |

### Logging

| Method | Direction | Description |
|--------|-----------|-------------|
| `logging/setLevel` | Client → Server | Set minimum log level |
| `notifications/message` | Server → Client | Log message from server |

### Progress

| Method | Direction | Description |
|--------|-----------|-------------|
| `notifications/progress` | Bidirectional | Progress update for long operation |

### Cancellation

| Method | Direction | Description |
|--------|-----------|-------------|
| `notifications/cancelled` | Bidirectional | Request cancelled |

---

## Request Parameter Schemas

### tools/list

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": {}  // or omit params
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "search_files",
        "description": "Search files by pattern",
        "inputSchema": {
          "type": "object",
          "properties": {
            "pattern": {"type": "string"},
            "path": {"type": "string"}
          },
          "required": ["pattern"]
        }
      }
    ]
  }
}
```

**Result schema:**
```typescript
{
  tools: Array<{
    name: string;           // Unique tool identifier
    description?: string;   // Human-readable description
    inputSchema: object;    // JSON Schema for arguments
  }>
}
```

### tools/call

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "search_files",
    "arguments": {
      "pattern": "*.ex",
      "path": "/src"
    }
  }
}
```

**Response (success):**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Found 42 files matching *.ex"
      }
    ],
    "isError": false
  }
}
```

**Response (tool error):**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Error: Path /src does not exist"
      }
    ],
    "isError": true
  }
}
```

**Params schema:**
```typescript
{
  name: string;         // Tool name from tools/list
  arguments?: object;   // Tool-specific arguments (validated by inputSchema)
}
```

**Result schema:**
```typescript
{
  content: Array<{
    type: "text" | "image" | "resource";
    text?: string;        // For type: text
    data?: string;        // For type: image (base64)
    mimeType?: string;    // For type: image
    uri?: string;         // For type: resource
  }>;
  isError?: boolean;     // True if tool execution failed
}
```

### resources/list

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "resources/list",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "resources": [
      {
        "uri": "file:///path/to/file.txt",
        "name": "file.txt",
        "description": "A text file",
        "mimeType": "text/plain"
      }
    ]
  }
}
```

**Result schema:**
```typescript
{
  resources: Array<{
    uri: string;          // Unique resource identifier
    name: string;         // Human-readable name
    description?: string; // Description
    mimeType?: string;    // MIME type
  }>
}
```

### resources/read

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "resources/read",
  "params": {
    "uri": "file:///path/to/file.txt"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "contents": [
      {
        "uri": "file:///path/to/file.txt",
        "mimeType": "text/plain",
        "text": "File contents here..."
      }
    ]
  }
}
```

**Params schema:**
```typescript
{
  uri: string;  // Resource URI from resources/list
}
```

**Result schema:**
```typescript
{
  contents: Array<{
    uri: string;          // Resource URI
    mimeType?: string;    // Content MIME type
    text?: string;        // For text content
    blob?: string;        // For binary content (base64)
  }>
}
```

### resources/subscribe

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "resources/subscribe",
  "params": {
    "uri": "file:///path/to/file.txt"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {}
}
```

**Server sends notifications when resource changes:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/resources/updated",
  "params": {
    "uri": "file:///path/to/file.txt"
  }
}
```

### prompts/list

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "prompts/list",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "prompts": [
      {
        "name": "summarize",
        "description": "Summarize text",
        "arguments": [
          {
            "name": "text",
            "description": "Text to summarize",
            "required": true
          }
        ]
      }
    ]
  }
}
```

**Result schema:**
```typescript
{
  prompts: Array<{
    name: string;
    description?: string;
    arguments?: Array<{
      name: string;
      description?: string;
      required?: boolean;
    }>;
  }>
}
```

### prompts/get

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "prompts/get",
  "params": {
    "name": "summarize",
    "arguments": {
      "text": "Long text to summarize..."
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "description": "Summarization prompt",
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Please summarize: Long text to summarize..."
        }
      }
    ]
  }
}
```

**Params schema:**
```typescript
{
  name: string;          // Prompt name from prompts/list
  arguments?: object;    // Prompt-specific arguments
}
```

**Result schema:**
```typescript
{
  description?: string;
  messages: Array<{
    role: "user" | "assistant";
    content: {
      type: "text" | "image" | "resource";
      text?: string;
      data?: string;        // base64 for images
      mimeType?: string;
      uri?: string;
    };
  }>;
}
```

### sampling/createMessage

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "Hello!"
        }
      }
    ],
    "modelPreferences": {
      "hints": [
        {"name": "claude-3-5-sonnet-20241022"}
      ],
      "costPriority": 0.5,
      "speedPriority": 0.5,
      "intelligencePriority": 0.9
    },
    "systemPrompt": "You are a helpful assistant.",
    "includeContext": "thisServer",
    "temperature": 0.7,
    "maxTokens": 1000,
    "stopSequences": ["\n\n"],
    "metadata": {}
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "role": "assistant",
    "content": {
      "type": "text",
      "text": "Hi there! How can I help you?"
    },
    "model": "claude-3-5-sonnet-20241022",
    "stopReason": "endTurn"
  }
}
```

**Params schema:**
```typescript
{
  messages: Array<Message>;      // Conversation history
  modelPreferences?: {           // Model selection hints
    hints?: Array<{name: string}>;
    costPriority?: number;       // 0-1
    speedPriority?: number;      // 0-1
    intelligencePriority?: number; // 0-1
  };
  systemPrompt?: string;
  includeContext?: "none" | "thisServer" | "allServers";
  temperature?: number;
  maxTokens: number;             // Required
  stopSequences?: string[];
  metadata?: object;
}
```

**Result schema:**
```typescript
{
  role: "assistant";
  content: Content;              // Text/image content
  model: string;                 // Model that generated response
  stopReason?: "endTurn" | "stopSequence" | "maxTokens";
}
```

### logging/setLevel

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "logging/setLevel",
  "params": {
    "level": "info"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {}
}
```

**Params schema:**
```typescript
{
  level: "debug" | "info" | "notice" | "warning" | "error" | "critical" | "alert" | "emergency";
}
```

**Server sends log messages:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "info",
    "logger": "server.database",
    "data": "Connected to database"
  }
}
```

---

## Progress Tokens

For long-running operations, progress updates can be sent:

**Request with progress token:**
```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "tools/call",
  "params": {
    "name": "long_operation",
    "arguments": {},
    "_meta": {
      "progressToken": "operation-123"
    }
  }
}
```

**Progress notifications:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/progress",
  "params": {
    "progressToken": "operation-123",
    "progress": 0.5,
    "total": 1.0
  }
}
```

**Progress schema:**
```typescript
{
  progressToken: string | number;  // Matches token from request
  progress: number;                // Current progress
  total?: number;                  // Total (for percentage calculation)
}
```

---

## Cancellation

**Cancel notification:**
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/cancelled",
  "params": {
    "requestId": 10,
    "reason": "User cancelled"
  }
}
```

**Cancellation schema:**
```typescript
{
  requestId: string | number;  // ID of request to cancel
  reason?: string;             // Optional reason
}
```

**Server behavior:**
- Best-effort cancellation
- May still send response (if already processed)
- No guaranteed cancellation in MVP (deferred to post-MVP)

---

## Ping/Pong

**Ping request (either direction):**
```json
{
  "jsonrpc": "2.0",
  "id": 999,
  "method": "ping",
  "params": {}
}
```

**Pong response:**
```json
{
  "jsonrpc": "2.0",
  "id": 999,
  "result": {}
}
```

Used for keepalive, latency checks, connection validation.

---

## Content Types

MCP supports multiple content types in tool results, prompts, and resources:

### Text Content

```json
{
  "type": "text",
  "text": "Content here"
}
```

### Image Content

```json
{
  "type": "image",
  "data": "base64-encoded-image-data",
  "mimeType": "image/png"
}
```

### Resource Content

```json
{
  "type": "resource",
  "uri": "file:///path/to/resource",
  "mimeType": "application/json"
}
```

**Client handling:**
```elixir
def process_content(%{"type" => "text", "text" => text}) do
  {:text, text}
end

def process_content(%{"type" => "image", "data" => data, "mimeType" => mime}) do
  {:image, Base.decode64!(data), mime}
end

def process_content(%{"type" => "resource", "uri" => uri}) do
  {:resource, uri}
end
```

---

## Protocol Validation

### Client-Side Validation

**On send (request):**
- ✅ Valid JSON
- ✅ `jsonrpc` = `"2.0"`
- ✅ `method` is string
- ✅ `id` is number or string (if present)
- ✅ `params` is object or array (if present)

**On receive (response):**
- ✅ Valid JSON
- ✅ `jsonrpc` = `"2.0"`
- ✅ Has `result` XOR `error` (not both, not neither)
- ✅ `id` matches sent request
- ✅ `error` has `code` (integer) and `message` (string)

**Invalid messages:**
- Log warning
- Increment telemetry counter
- Discard message
- Continue operation (don't crash)

---

## Implementation Guidelines

### Message Correlation

```elixir
defmodule ConnectionState do
  defstruct [
    next_id: 1,                    # Monotonic request ID
    requests: %{},                 # id => request_data
    # ...
  ]
end

def send_request(state, method, params) do
  id = state.next_id
  request = %{
    id: id,
    method: method,
    params: params,
    sent_at: System.monotonic_time(:millisecond)
  }

  frame = Jason.encode!(%{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => method,
    "params" => params
  })

  state = %{state |
    next_id: id + 1,
    requests: Map.put(state.requests, id, request)
  }

  {frame, state}
end

def handle_response(state, %{"id" => id, "result" => result}) do
  case Map.pop(state.requests, id) do
    {nil, _} ->
      # Unknown ID (late response after timeout/cancel)
      Logger.debug("Unknown response ID: #{id}")
      state

    {request, requests} ->
      # Match response to request
      reply_to_caller(request, {:ok, result})
      %{state | requests: requests}
  end
end
```

### Capability Checking

```elixir
def call_with_capability_check(conn, method, params, required_capability) do
  caps = McpClient.server_capabilities(conn)

  if supports_capability?(caps, required_capability) do
    Connection.call(conn, method, params)
  else
    {:error, %Error{
      type: :capability_not_supported,
      message: "Server does not support #{inspect(required_capability)}"
    }}
  end
end

# Usage:
def subscribe(conn, uri, opts) do
  call_with_capability_check(
    conn,
    "resources/subscribe",
    %{uri: uri},
    [:resources, :subscribe]
  )
end
```

---

## References

- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **JSON-RPC 2.0**: https://www.jsonrpc.org/specification
- **JSON Schema**: https://json-schema.org/
- **MVP_SPEC.md**: Complete state machine and lifecycle
- **CLIENT_FEATURES.md**: High-level API design

---

**Status**: Reference document for implementation
**Next**: Use schemas in feature module validation and testing
