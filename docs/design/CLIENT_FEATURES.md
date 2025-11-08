# Client Features Design

**Date:** 2025-11-07
**Status:** Accepted
**Related:** ADR-0011 Client Features Architecture

## Overview

This document specifies the high-level API design for MCP client features built on top of the core connection layer. Each feature domain (Tools, Resources, Prompts, Sampling, Roots, Logging) is implemented as a separate module following consistent patterns.

## Architecture Principles

### 1. Clean Core Boundary

Features **only** use these three core functions:
```elixir
Connection.call(pid, method, params, timeout) :: {:ok, map()} | {:error, term()}
Connection.notify(pid, method, params) :: :ok
Connection.start_link(opts) :: {:ok, pid()} | {:error, term()}
```

### 2. Consistent Module Pattern

Every feature module follows this structure:
- Request functions (public API)
- Response validation (private)
- TypedStruct definitions for responses
- Error normalization through `McpClient.Error`

### 3. Type Safety

All responses are validated and converted to typed structs using `TypedStruct`.

### 4. Error Normalization

All errors flow through `McpClient.Error.normalize/2` for consistent handling.

### 5. Capability Guards

Every feature call checks that the server advertised the capability before issuing RPCs:

```elixir
defp ensure_capability(conn, capability) do
  with {:ok, caps} <- Connection.server_capabilities(conn),
       true <- Map.get(caps, capability, false) do
    :ok
  else
    _ ->
      {:error,
       %Error{
         type: :capability_not_supported,
         message: "server does not advertise #{capability}",
         details: %{capability: capability}
       }}
  end
end
```

Each feature module calls `ensure_capability/2` (or its module-local equivalent) before delegating to `Connection.call/4`.

### 6. Tool Execution Modes

The tools feature exposes whether a definition must run inside the shared session (`:stateful`) or can run in an isolated request process (`:stateless`). The Connection engages session tracking only when at least one stateful tool is available; otherwise, calls skip `session_id` metadata entirely. ADR-0012 details how this feeds back into the state machine.

---

## Dual Usage Pattern Support

The client features API supports **two usage patterns** without modification:

### Pattern A: Direct Tool Calls (MVP)

Agent loads tool definitions into context and calls through feature modules:

```elixir
# 1. List tools (definitions go into agent context)
{:ok, tools} = McpClient.Tools.list(conn)
# Agent sees: Tool definitions (150K tokens for 1000 tools)

# 2. Agent decides to call a tool
{:ok, result} = McpClient.Tools.call(conn, "google_drive__get_document", %{
  documentId: "abc123"
})
# Agent sees: Document content (50K tokens)
```

**Use case:** < 50 tools, simple workflows, model reasoning about tool selection

### Pattern B: Code Execution (Post-MVP)

Generated modules wrap feature API, agent writes code:

```elixir
# Generated wrapper (post-MVP tooling: mix mcp.gen.client)
defmodule MCPServers.GoogleDrive do
  def get_document(conn, document_id) do
    McpClient.Tools.call(conn, "google_drive__get_document", %{
      documentId: document_id
    })
  end
end

# Agent writes code using wrappers
alias MCPServers.GoogleDrive
{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
# Agent sees: Just the code (3 tokens: "Done")
# Agent does NOT see: Tool definitions (0 tokens), document content (0 tokens)
```

**Use case:** 100+ tools, complex workflows, privacy-sensitive data

### Key Insight: Same API, Different Consumption

Both patterns use **identical client features API** (`McpClient.Tools.call/4`, etc.):

- **Pattern A**: Agent calls API directly, sees everything
- **Pattern B**: Generated code calls API, agent sees nothing (data in memory)

**Token efficiency:**
- Pattern A (1000 tools): 150K (tools) + 50K (data) = 200K tokens
- Pattern B (1000 tools): 0 (tools) + 0 (data) + 3 (code) = 3 tokens
- **Reduction: 98.7%** (200K → 3K)

**Post-MVP work:**
- Code generation tool (`mix mcp.gen.client`) - generates wrappers
- Progressive tool discovery - load tools on-demand
- Skills pattern - reusable agent code libraries

See [CODE_EXECUTION_PATTERN.md](CODE_EXECUTION_PATTERN.md) for complete details.

### Design Impact

Client features API **does not change** for code execution pattern:
- ✅ Same Connection.call/4 foundation
- ✅ Same error handling
- ✅ Same response types
- ✅ Same notification routing

The **only difference** is who calls the API:
- Pattern A: Agent calls directly
- Pattern B: Generated code calls (agent writes the code)

This design ensures:
1. **No breaking changes** when Pattern B launches (v0.2.x)
2. **Mix patterns** in same application (Direct for simple servers, Code for complex)
3. **Server compatibility** - servers see identical requests either way

### Session Behavior and Tool Modes

- When *all* tools are `:stateless`, the connection runs in **session-optional** mode: `session_id` metadata is omitted, and each tool call executes inside an isolated request process for fault containment.
- When **any** tool is `:stateful`, the connection flips into **session-required** mode: every request (including stateless ones) carries the current `session_id`, and stateful calls execute inside the Connection process to access shared transport state.
- Switching modes happens automatically whenever the server updates its tool list; no application code changes are required.
- Stateless executions use the dedicated `Task.Supervisor` started alongside the connection (override via `:stateless_supervisor` option) so CPU-heavy work never blocks the Connection mailbox.

---

## Feature Modules

### McpClient.Tools

**Purpose:** Execute server-provided functions with validated arguments.

**API:**
```elixir
@spec list(pid(), Keyword.t()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
def list(conn, opts \\ [])

@spec call(pid(), String.t(), map(), Keyword.t()) ::
  {:ok, CallResult.t()} | {:error, Error.t()}
def call(conn, name, arguments, opts \\ [])
```

**Types:**
```elixir
defmodule Tool do
  use TypedStruct
  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :inputSchema, map(), enforce: true  # JSON Schema
    field :mode, atom(), default: :stateful   # :stateful | :stateless
  end
end

defmodule CallResult do
  use TypedStruct
  typedstruct do
    field :content, [map()], default: []  # Array of content items
    field :isError, boolean(), default: false
  end
end
```

**MCP Methods:**
- `tools/list` → `list/2`
- `tools/call` → `call/4`

**Capability:** Requires server capability `:tools`; every call begins with `ensure_capability(conn, :tools)` before issuing RPCs.

**Server Notifications:**
- `notifications/tools/list_changed` - tools available changed

**Example:**
```elixir
{:ok, tools} = McpClient.Tools.list(conn)
# [%McpClient.Tools.Tool{name: "search", description: "Search files", mode: :stateless, ...}]

{:ok, result} = McpClient.Tools.call(conn, "search", %{query: "TODO"})
# %McpClient.Tools.CallResult{content: [...], isError: false}
```

---

### McpClient.Resources

**Purpose:** Read and monitor server-provided data sources (files, URLs, database queries).

**API:**
```elixir
@spec list(pid(), Keyword.t()) :: {:ok, [Resource.t()]} | {:error, Error.t()}
def list(conn, opts \\ [])

@spec read(pid(), String.t(), Keyword.t()) ::
  {:ok, ResourceContents.t()} | {:error, Error.t()}
def read(conn, uri, opts \\ [])

@spec subscribe(pid(), String.t(), Keyword.t()) :: :ok | {:error, Error.t()}
def subscribe(conn, uri, opts \\ [])

@spec unsubscribe(pid(), String.t(), Keyword.t()) :: :ok | {:error, Error.t()}
def unsubscribe(conn, uri, opts \\ [])

@spec list_templates(pid(), Keyword.t()) ::
  {:ok, [ResourceTemplate.t()]} | {:error, Error.t()}
def list_templates(conn, opts \\ [])
```

**Types:**
```elixir
defmodule Resource do
  use TypedStruct
  typedstruct do
    field :uri, String.t(), enforce: true
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :mimeType, String.t()
  end
end

defmodule ResourceContents do
  use TypedStruct
  typedstruct do
    field :contents, [map()], enforce: true  # Array of content items
    field :uri, String.t(), enforce: true
  end
end

defmodule ResourceTemplate do
  use TypedStruct
  typedstruct do
    field :uriTemplate, String.t(), enforce: true
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :mimeType, String.t()
  end
end
```

**MCP Methods:**
- `resources/list` → `list/2`
- `resources/read` → `read/3`
- `resources/subscribe` → `subscribe/3`
- `resources/unsubscribe` → `unsubscribe/3`
- `resources/templates/list` → `list_templates/2`

**Capability:** Requires server capability `:resources`; every list/read/subscribe function calls `ensure_capability(conn, :resources)` before delegating.

**Server Notifications:**
- `notifications/resources/updated` - resource content changed
- `notifications/resources/list_changed` - available resources changed

**Example:**
```elixir
{:ok, resources} = McpClient.Resources.list(conn)
# [%McpClient.Resources.Resource{uri: "file:///foo", name: "foo", ...}]

{:ok, contents} = McpClient.Resources.read(conn, "file:///foo")
# %McpClient.Resources.ResourceContents{contents: [...], uri: "file:///foo"}

:ok = McpClient.Resources.subscribe(conn, "file:///foo")
# Server will send notifications/resources/updated when file changes
```

---

### McpClient.Prompts

**Purpose:** Retrieve and execute server-provided prompt templates for LLM interactions.

**API:**
```elixir
@spec list(pid(), Keyword.t()) :: {:ok, [Prompt.t()]} | {:error, Error.t()}
def list(conn, opts \\ [])

@spec get(pid(), String.t(), map(), Keyword.t()) ::
  {:ok, GetPromptResult.t()} | {:error, Error.t()}
def get(conn, name, arguments \\ %{}, opts \\ [])
```

**Types:**
```elixir
defmodule Prompt do
  use TypedStruct
  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :arguments, [PromptArgument.t()], default: []
  end
end

defmodule PromptArgument do
  use TypedStruct
  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :required, boolean(), default: false
  end
end

defmodule GetPromptResult do
  use TypedStruct
  typedstruct do
    field :description, String.t()
    field :messages, [PromptMessage.t()], enforce: true
  end
end

defmodule PromptMessage do
  use TypedStruct
  typedstruct do
    field :role, String.t(), enforce: true  # "user" | "assistant"
    field :content, map(), enforce: true    # Text or image content
  end
end
```

**MCP Methods:**
- `prompts/list` → `list/2`
- `prompts/get` → `get/4`

**Capability:** Requires server capability `:prompts`; both functions call `ensure_capability(conn, :prompts)` before issuing the RPC.

**Server Notifications:**
- `notifications/prompts/list_changed` - available prompts changed

**Example:**
```elixir
{:ok, prompts} = McpClient.Prompts.list(conn)
# [%McpClient.Prompts.Prompt{name: "summarize", description: "...", ...}]

{:ok, result} = McpClient.Prompts.get(conn, "summarize", %{text: "..."})
# %McpClient.Prompts.GetPromptResult{
#   messages: [%PromptMessage{role: "user", content: %{type: "text", text: "..."}}]
# }
```

---

### McpClient.Sampling

**Purpose:** Request LLM completions from the server (server-side sampling).

**API:**
```elixir
@spec create_message(pid(), SamplingRequest.t(), Keyword.t()) ::
  {:ok, SamplingResult.t()} | {:error, Error.t()}
def create_message(conn, request, opts \\ [])
```

**Types:**
```elixir
defmodule SamplingRequest do
  use TypedStruct
  typedstruct do
    field :messages, [map()], enforce: true     # Array of message objects
    field :modelPreferences, map()              # Model hints
    field :systemPrompt, String.t()
    field :includeContext, String.t()           # "none" | "thisServer" | "allServers"
    field :temperature, float()
    field :maxTokens, integer(), enforce: true
    field :stopSequences, [String.t()], default: []
    field :metadata, map()
  end
end

defmodule SamplingResult do
  use TypedStruct
  typedstruct do
    field :role, String.t(), enforce: true      # "assistant"
    field :content, map(), enforce: true        # Text or image content
    field :model, String.t(), enforce: true     # Model used
    field :stopReason, String.t()               # Why generation stopped
  end
end
```

**MCP Methods:**
- `sampling/createMessage` → `create_message/3`

**Capability:** Requires server capability `:sampling`; `create_message/3` calls `ensure_capability(conn, :sampling)` before sending the request.

**Example:**
```elixir
request = %McpClient.Sampling.SamplingRequest{
  messages: [%{role: "user", content: %{type: "text", text: "Hello"}}],
  maxTokens: 100,
  temperature: 0.7
}

{:ok, result} = McpClient.Sampling.create_message(conn, request)
# %McpClient.Sampling.SamplingResult{
#   role: "assistant",
#   content: %{type: "text", text: "Hi there!"},
#   model: "claude-3-5-sonnet-20241022",
#   stopReason: "endTurn"
# }
```

---

### McpClient.Roots

**Purpose:** Manage client workspace boundaries and file access permissions.

**API:**
```elixir
@spec list(pid(), Keyword.t()) :: {:ok, [Root.t()]} | {:error, Error.t()}
def list(conn, opts \\ [])
```

**Types:**
```elixir
defmodule Root do
  use TypedStruct
  typedstruct do
    field :uri, String.t(), enforce: true       # file:// or other scheme
    field :name, String.t()
  end
end
```

**MCP Methods:**
- `roots/list` → `list/2`

**Capability:** Requires server capability `:roots`; `list/2` should call `ensure_capability(conn, :roots)` when querying the server for roots metadata.

**Server Requests (handled by client):**
- Server can call `roots/list` on the client to discover allowed paths
- Not a typical client → server request; client provides this capability

**Example:**
```elixir
# Client declares roots during initialization
{:ok, conn} = McpClient.start_link(
  transport: {...},
  client_capabilities: %{
    roots: %{listChanged: true}
  },
  roots: [
    %{uri: "file:///home/user/project", name: "Project"},
    %{uri: "file:///home/user/documents", name: "Documents"}
  ]
)

# If server requests roots list, client responds automatically
# Application can also query configured roots
{:ok, roots} = McpClient.Roots.list(conn)
```

---

### McpClient.Logging

**Purpose:** Control server log levels and receive log messages.

**API:**
```elixir
@spec set_level(pid(), log_level(), Keyword.t()) :: :ok | {:error, Error.t()}
def set_level(conn, level, opts \\ [])
```

**Types:**
```elixir
@type log_level :: :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency

defmodule LogMessage do
  use TypedStruct
  typedstruct do
    field :level, String.t(), enforce: true
    field :logger, String.t()
    field :data, term(), enforce: true
  end
end
```

**MCP Methods:**
- `logging/setLevel` → `set_level/3`

**Capability:** Requires server capability `:logging`; `set_level/3` first ensures the capability is advertised.

**Server Notifications:**
- `notifications/message` - server log message

**Example:**
```elixir
# Set minimum log level
:ok = McpClient.Logging.set_level(conn, :info)

# Receive logs via notification handler
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: fn notification ->
    case McpClient.NotificationRouter.route(notification) do
      {:logging, :message, params} ->
        Logger.log(
          params["level"] |> String.to_existing_atom(),
          "[MCP Server] #{inspect(params["data"])}"
        )
      _ -> :ok
    end
  end
)
```

---

## Shared Infrastructure

### McpClient.Error

**Purpose:** Normalize all error types into structured, informative errors.

**Definition:**
```elixir
defmodule McpClient.Error do
  use TypedStruct

  typedstruct do
    field :type, error_type(), enforce: true
    field :message, String.t(), enforce: true
    field :operation, atom()                    # :tools_list, :resources_read, etc.
    field :details, map()                       # Additional context
    field :server_error, map()                  # Original JSON-RPC error
  end

  @type error_type ::
    :timeout
    | :connection_closed
    | :invalid_response
    | :method_not_found
    | :invalid_params
    | :internal_error
    | :transport_error
    | :decode_error
    | :oversized_frame
    | :capability_mismatch

  @spec normalize(term(), atom()) :: t()
  def normalize(reason, operation)
end
```

**Usage in feature modules:**
```elixir
def list(conn, opts) do
  with {:ok, result} <- Connection.call(conn, "tools/list", %{}, opts[:timeout]),
       {:ok, tools} <- validate_response(result) do
    {:ok, tools}
  else
    {:error, reason} -> {:error, Error.normalize(reason, :tools_list)}
  end
end
```

### McpClient.NotificationRouter

**Purpose:** Route server-initiated notifications to typed callbacks.

**Definition:**
```elixir
defmodule McpClient.NotificationRouter do
  @type notification :: map()
  @type route ::
    {:tools, :list_changed, params :: map()}
    | {:resources, :updated, params :: map()}
    | {:resources, :list_changed, params :: map()}
    | {:prompts, :list_changed, params :: map()}
    | {:logging, :message, params :: map()}
    | {:progress, params :: map()}
    | {:unknown, notification()}

  @spec route(notification()) :: route()
  def route(%{"method" => method, "params" => params})
end
```

**Usage:**
```elixir
{:ok, conn} = McpClient.start_link(
  transport: {...},
  notification_handler: fn notification ->
    case NotificationRouter.route(notification) do
      {:resources, :updated, %{"uri" => uri}} ->
        MyApp.invalidate_cache(uri)

      {:tools, :list_changed, _params} ->
        MyApp.refresh_tool_list(conn)

      {:progress, %{"progressToken" => token, "progress" => progress}} ->
        MyApp.update_progress(token, progress)

      _ -> :ok
    end
  end
)
```

---

## Implementation Checklist

### Phase 1: Infrastructure (Do First)
- [ ] `McpClient.Error` module with normalization logic
- [ ] `McpClient.NotificationRouter` module with routing logic
- [ ] Integration tests with mock connection
- [ ] Documentation examples

### Phase 2: Core Features (Priority Order)
- [ ] `McpClient.Tools` (highest priority - most common)
- [ ] `McpClient.Resources` (file/data access)
- [ ] `McpClient.Prompts` (LLM interaction)

### Phase 3: Advanced Features
- [ ] `McpClient.Sampling` (server-side completions)
- [ ] `McpClient.Roots` (workspace management)
- [ ] `McpClient.Logging` (server log control)

### Phase 4: Integration & Polish
- [ ] Integration tests with real MCP servers
- [ ] Update `McpClient` main module documentation
- [ ] Add usage examples to README
- [ ] Add guides for each feature domain

---

## Testing Strategy

### Unit Tests (Per Module)

Each feature module should have:
1. **Request construction tests** - verify correct JSON-RPC method/params
2. **Response validation tests** - verify struct creation from various responses
3. **Error normalization tests** - verify all error paths produce Error structs
4. **Mock connection tests** - feature works with mock `Connection.call/4`

**Example:**
```elixir
defmodule McpClient.ToolsTest do
  use ExUnit.Case
  import Mox

  setup :verify_on_exit!

  test "list/1 sends correct JSON-RPC request" do
    MockConnection
    |> expect(:call, fn _conn, "tools/list", %{}, 30_000 ->
      {:ok, %{"tools" => []}}
    end)

    assert {:ok, []} = McpClient.Tools.list(:mock_conn)
  end

  test "list/1 validates response structure" do
    MockConnection
    |> expect(:call, fn _, _, _, _ ->
      {:ok, %{"tools" => [%{"name" => "test", "inputSchema" => %{}}]}}
    end)

    assert {:ok, [%Tool{name: "test"}]} = McpClient.Tools.list(:mock_conn)
  end

  test "list/1 normalizes errors" do
    MockConnection
    |> expect(:call, fn _, _, _, _ -> {:error, :timeout} end)

    assert {:error, %Error{type: :timeout, operation: :tools_list}} =
      McpClient.Tools.list(:mock_conn)
  end
end
```

### Integration Tests

Test against real MCP servers:
1. **Reference server tests** - use official MCP reference servers
2. **Popular server tests** - sqlite, filesystem, GitHub, etc.
3. **Notification tests** - verify routing and handling
4. **Error condition tests** - malformed responses, timeouts, etc.

---

## Documentation Requirements

### Module Documentation

Each feature module must include:
1. **@moduledoc** - purpose, typical use cases
2. **Function docs** - parameters, return types, examples
3. **Type docs** - explain each struct field
4. **Common errors** - what errors users might encounter

### Usage Examples

Provide complete examples for:
1. **Basic usage** - simplest working example
2. **With options** - timeout configuration, etc.
3. **Error handling** - pattern matching on Error types
4. **Notification handling** - wiring up callbacks

### Guides

Add guides for:
1. **Getting Started** - quick start with Tools
2. **Resource Management** - reading files, subscribing to changes
3. **Prompt Engineering** - using prompt templates
4. **Advanced Topics** - notification routing, error recovery

---

## Performance Considerations

### MVP: Simple and Correct

- All operations are synchronous (block caller until response)
- No caching (application concern)
- No batching (one request at a time)
- No connection pooling (single connection per server)

### Post-MVP Optimizations (Deferred)

**If profiling shows need:**
- Async operations (return task/stream instead of blocking)
- Batch operations (`call_many/2`, `read_many/2`)
- Response caching with TTL
- Connection pooling for high-throughput scenarios

---

## References

- **ADR-0011**: Client Features Architecture
- **ADR-0010**: MVP Scope and Deferrals
- **MCP Specification**: https://spec.modelcontextprotocol.io/
  - Protocol primitives documentation
  - JSON-RPC 2.0 specification
  - Server notification specifications
- **Elixir TypedStruct**: https://hexdocs.pm/typed_struct/
- **Elixir Error Handling**: https://hexdocs.pm/elixir/library-guidelines.html#avoid-exceptions-for-control-flow

---

**Status**: Ready for implementation after core (PROMPT_01-09) complete
**Next Step**: Implement `McpClient.Error` and `McpClient.NotificationRouter` as foundation
