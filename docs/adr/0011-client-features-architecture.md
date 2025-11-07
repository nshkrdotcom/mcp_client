# 11. Client Features Architecture

**Status:** Accepted
**Date:** 2025-11-07
**Deciders:** Engineering Team
**Context:** MCP Client Library MVP Design

## Context and Problem Statement

The core connection layer (PROMPT_01-09) provides low-level request/response primitives (`Connection.call/4`, `Connection.notify/3`) and manages the connection lifecycle. However, end users need high-level, type-safe APIs for MCP primitives (Tools, Resources, Prompts, Sampling, Roots, Logging).

We must decide how to structure these client features on top of the core, balancing:
- **Ergonomics**: Simple, intuitive API that feels natural in Elixir
- **Type safety**: Validation and structured responses
- **Extensibility**: Easy to add new MCP features as spec evolves
- **Isolation**: Clean separation between core and features (avoid spaghetti)
- **Error handling**: Consistent, informative error reporting

Without a clear architecture, we risk:
- Tight coupling between features and core (hard to maintain)
- Inconsistent API patterns across features
- Leaky abstractions exposing JSON-RPC details to users
- Difficulty handling server-initiated notifications

## Decision Drivers

- Maintain clean boundary between core and features (3-function API)
- Provide idiomatic Elixir API (not raw JSON-RPC)
- Enable incremental feature implementation (can ship partial features)
- Support server-initiated notifications (resource updates, logging)
- Keep features testable in isolation (mock-friendly)
- Avoid premature optimization (simple > clever for MVP)
- Follow Elixir conventions (Ecto, Req, Finch patterns)

## Considered Options

### Option 1: Single MCPClient module with namespaced functions

```elixir
MCPClient.tools_list(conn)
MCPClient.tools_call(conn, name, args)
MCPClient.resources_read(conn, uri)
```

**Pros:**
- Simple, flat API
- Easy discoverability

**Cons:**
- Namespace pollution (10+ functions at top level)
- No logical grouping of related features
- Hard to extend per-feature behavior

### Option 2: Separate feature modules with shared core

```elixir
MCPClient.Tools.list(conn)
MCPClient.Tools.call(conn, name, args)
MCPClient.Resources.read(conn, uri)
```

**Pros:**
- Logical grouping by feature domain
- Each module can have feature-specific helpers
- Clear separation of concerns
- Easy to document per-feature

**Cons:**
- Slightly more verbose
- User must know which module to use

### Option 3: Protocol-based polymorphism

```elixir
MCPClient.list(conn, :tools)
MCPClient.call(conn, :tools, %{name: "search", args: %{}})
```

**Pros:**
- Single entry point
- Runtime dispatch flexibility

**Cons:**
- Less type-safe (atoms instead of modules)
- Harder to document
- No compile-time checks
- Not idiomatic Elixir

## Decision Outcome

Chosen option: **Separate feature modules with shared core (Option 2)**, because:

1. **Idiomatic Elixir**: Follows patterns from Ecto (`Ecto.Repo`, `Ecto.Query`), Req (`Req.get`, `Req.post`), Phoenix (`Phoenix.Channel`, `Phoenix.PubSub`)
2. **Clean boundaries**: Each module encapsulates one MCP feature domain
3. **Extensible**: Easy to add new features without modifying existing modules
4. **Type safety**: Each module can define feature-specific structs and validation
5. **Testable**: Each feature module can be tested independently with mock connections
6. **Discoverable**: `h MCPClient.Tools` shows all tool-related functions

### Implementation Structure

**Module organization:**
```elixir
lib/
  mcp_client.ex                    # Main API, connection lifecycle
  mcp_client/
    # Core (PROMPT_01-09)
    connection.ex                  # State machine
    transport.ex                   # Behavior
    transports/
      stdio.ex
      sse.ex
      http.ex
    error.ex                       # Error types

    # Client Features (post-MVP-core)
    tools.ex                       # MCPClient.Tools
    resources.ex                   # MCPClient.Resources
    prompts.ex                     # MCPClient.Prompts
    sampling.ex                    # MCPClient.Sampling
    roots.ex                       # MCPClient.Roots
    logging.ex                     # MCPClient.Logging
    notification_router.ex         # Server notification dispatcher
```

### API Design Pattern

Each feature module follows this pattern:

```elixir
defmodule MCPClient.Tools do
  @moduledoc """
  Client API for MCP Tools feature.

  Tools allow servers to expose executable functions that can be called
  by the client with validated arguments.
  """

  alias MCPClient.Connection
  alias MCPClient.Error

  # List available tools
  @spec list(pid(), Keyword.t()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, result} <- Connection.call(conn, "tools/list", %{}, timeout),
         {:ok, tools} <- validate_tools_response(result) do
      {:ok, tools}
    else
      {:error, reason} -> {:error, Error.normalize(reason, :tools_list)}
    end
  end

  # Call a specific tool
  @spec call(pid(), String.t(), map(), Keyword.t()) ::
    {:ok, CallResult.t()} | {:error, Error.t()}
  def call(conn, name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    params = %{name: name, arguments: arguments}

    with {:ok, result} <- Connection.call(conn, "tools/call", params, timeout),
         {:ok, call_result} <- validate_call_response(result) do
      {:ok, call_result}
    else
      {:error, reason} -> {:error, Error.normalize(reason, :tools_call)}
    end
  end

  # Private: Validate and structure response
  defp validate_tools_response(%{"tools" => tools}) when is_list(tools) do
    tools = Enum.map(tools, &struct!(Tool, &1))
    {:ok, tools}
  end
  defp validate_tools_response(_), do: {:error, :invalid_response}

  # TypedStruct for response types
  defmodule Tool do
    use TypedStruct

    typedstruct do
      field :name, String.t(), enforce: true
      field :description, String.t()
      field :inputSchema, map(), enforce: true
    end
  end

  defmodule CallResult do
    use TypedStruct

    typedstruct do
      field :content, [map()], default: []
      field :isError, boolean(), default: false
    end
  end
end
```

### Core API Surface (Complete Contract)

The core exposes exactly **3 functions** to feature modules:

```elixir
defmodule MCPClient.Connection do
  # Synchronous request with correlation
  @spec call(pid(), method :: String.t(), params :: map(), timeout()) ::
    {:ok, result :: map()} | {:error, term()}
  def call(conn, method, params, timeout \\ 30_000)

  # Fire-and-forget notification (client → server)
  @spec notify(pid(), method :: String.t(), params :: map()) :: :ok
  def notify(conn, method, params)

  # Start with notification handler (server → client)
  @spec start_link(Keyword.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    # opts includes:
    # - transport: {module(), opts}
    # - notification_handler: (map() -> :ok)
    # - request_timeout, backoff_min, etc.
  end
end
```

**That's it.** Features never touch:
- State machine internals
- Transport layer
- Request tracking maps
- Retry logic
- Tombstone management
- Backoff state

### Notification Routing

Server-initiated notifications require special handling:

```elixir
defmodule MCPClient.NotificationRouter do
  @moduledoc """
  Routes server-initiated notifications to typed callbacks.

  Server notifications include:
  - notifications/resources/updated
  - notifications/resources/list_changed
  - notifications/tools/list_changed
  - notifications/prompts/list_changed
  - notifications/message (logging)
  - notifications/progress
  """

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
  def route(%{"method" => method, "params" => params}) do
    case method do
      "notifications/tools/list_changed" -> {:tools, :list_changed, params}
      "notifications/resources/updated" -> {:resources, :updated, params}
      "notifications/resources/list_changed" -> {:resources, :list_changed, params}
      "notifications/prompts/list_changed" -> {:prompts, :list_changed, params}
      "notifications/message" -> {:logging, :message, params}
      "progress" -> {:progress, params}
      _ -> {:unknown, %{method: method, params: params}}
    end
  end
  def route(notification), do: {:unknown, notification}
end
```

**User wiring:**

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {MCPClient.Transports.Stdio, cmd: "mcp-server"},
  notification_handler: fn notification ->
    case MCPClient.NotificationRouter.route(notification) do
      {:resources, :updated, params} ->
        MyApp.ResourceCache.invalidate(params["uri"])

      {:logging, :message, params} ->
        Logger.info("[MCP Server] #{params["data"]}")

      {:progress, params} ->
        MyApp.ProgressTracker.update(params["progressToken"], params["progress"])

      _ -> :ok
    end
  end
)
```

### Error Normalization

All feature modules normalize errors through a shared module:

```elixir
defmodule MCPClient.Error do
  @moduledoc """
  Normalized error types for MCP operations.
  """

  use TypedStruct

  typedstruct do
    field :type, error_type(), enforce: true
    field :message, String.t(), enforce: true
    field :operation, atom()
    field :details, map()
    field :server_error, map()  # Original JSON-RPC error if applicable
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

  @spec normalize(term(), atom()) :: t()
  def normalize(reason, operation) do
    # Convert various error types to structured Error
    case reason do
      :timeout ->
        %__MODULE__{
          type: :timeout,
          message: "Request timed out",
          operation: operation
        }

      {:jsonrpc_error, code, message, data} ->
        %__MODULE__{
          type: jsonrpc_code_to_type(code),
          message: message,
          operation: operation,
          details: data,
          server_error: %{code: code, message: message, data: data}
        }

      # ... more cases
    end
  end

  defp jsonrpc_code_to_type(-32601), do: :method_not_found
  defp jsonrpc_code_to_type(-32602), do: :invalid_params
  defp jsonrpc_code_to_type(-32603), do: :internal_error
  defp jsonrpc_code_to_type(_), do: :internal_error
end
```

### Response Validation Strategy

Each feature module validates JSON-RPC responses into typed structs:

**Why not JSON Schema?**
- TypedStruct provides compile-time checks
- Pattern matching is idiomatic Elixir
- Simpler for MVP (no runtime schema validation overhead)
- Can add JSON Schema validation post-MVP if needed

**Example validation:**

```elixir
defp validate_tools_response(%{"tools" => tools}) when is_list(tools) do
  case validate_all_tools(tools) do
    {:ok, validated_tools} -> {:ok, validated_tools}
    {:error, reason} -> {:error, {:invalid_tool, reason}}
  end
end
defp validate_tools_response(_), do: {:error, :missing_tools_field}

defp validate_all_tools(tools) do
  tools
  |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
    case validate_tool(tool) do
      {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end)
  |> case do
    {:ok, validated} -> {:ok, Enum.reverse(validated)}
    error -> error
  end
end

defp validate_tool(%{"name" => name, "inputSchema" => schema})
    when is_binary(name) and is_map(schema) do
  {:ok, %Tool{
    name: name,
    description: Map.get(tool, "description"),
    inputSchema: schema
  }}
end
defp validate_tool(_), do: {:error, :invalid_tool_structure}
```

## Consequences

### Positive

**Isolation:**
- ✅ Feature modules depend only on 3 core functions
- ✅ Zero reverse dependencies (core never calls features)
- ✅ Can test features with simple mock connection
- ✅ Can ship features incrementally (Tools first, Resources later, etc.)

**Usability:**
- ✅ Idiomatic Elixir API (follows ecosystem patterns)
- ✅ Type-safe responses with TypedStruct
- ✅ Consistent error handling across all features
- ✅ Clear documentation per feature module

**Maintainability:**
- ✅ Easy to add new MCP features (new module, same pattern)
- ✅ Easy to extend existing features (add functions to module)
- ✅ Clear ownership (Tools.ex owns all tool-related code)
- ✅ No namespace pollution at top level

**Flexibility:**
- ✅ Users can choose which features to use (only import needed modules)
- ✅ Can wrap features in application-specific logic
- ✅ Can compose features (e.g., tool chaining, resource caching)

### Negative/Risks

**Slightly more verbose:**
- ❌ `MCPClient.Tools.list(conn)` vs `MCPClient.tools_list(conn)`
- **Mitigation:** Standard in Elixir ecosystem, users expect this pattern

**Notification routing requires wiring:**
- ❌ User must set up notification_handler with router
- **Mitigation:** Provide examples in docs, helper functions

**Validation overhead:**
- ❌ Each response validated and restructured
- **Mitigation:** Minimal cost (sub-millisecond), can optimize post-MVP if needed

### Neutral

**Module count increases:**
- 6 feature modules (Tools, Resources, Prompts, Sampling, Roots, Logging)
- Plus NotificationRouter and Error modules
- Standard for full-featured libraries (acceptable)

**TypedStruct dependency:**
- Already in mix.exs for core, no new dependency

## Implementation Phases

### Phase 1: Core API Finalization (PROMPT_01-09)
- Implement `Connection.call/4`, `Connection.notify/3`
- Verify core API is sufficient for all features
- Add integration tests with mock responses

### Phase 2: Error & Router Infrastructure
- Implement `MCPClient.Error` with normalization
- Implement `MCPClient.NotificationRouter`
- Add tests for error types and routing logic

### Phase 3: Feature Modules (Incremental)
**Can be done in any order, ship incrementally:**

1. **MCPClient.Tools** (highest priority - most common use case)
   - `list/2`, `call/4`
   - `Tool` and `CallResult` structs

2. **MCPClient.Resources** (common for file/data access)
   - `list/2`, `read/3`, `subscribe/3`, `unsubscribe/3`, `list_templates/2`
   - `Resource`, `ResourceContents`, `ResourceTemplate` structs

3. **MCPClient.Prompts** (LLM interaction)
   - `list/2`, `get/3`
   - `Prompt`, `PromptMessage` structs

4. **MCPClient.Sampling** (LLM completions)
   - `create_message/3`
   - `SamplingRequest`, `SamplingResult` structs

5. **MCPClient.Roots** (workspace boundaries)
   - `list/2`
   - `Root` struct

6. **MCPClient.Logging** (server logs)
   - `set_level/3`
   - Handle `notifications/message` via router

### Phase 4: Integration & Documentation
- Update `MCPClient` main module with feature links
- Add usage examples for each feature
- Add integration tests with real MCP servers
- Update README with feature showcase

## Deferred to Post-MVP

**Advanced validation:**
- ❌ JSON Schema runtime validation
- ❌ Compile-time schema checking from MCP spec
- **Trigger:** User reports validation issues, need stricter checks

**Async operations:**
- ❌ Stream-based resource reading
- ❌ Async tool execution with cancellation
- **Trigger:** Large resource handling, long-running tool performance

**Feature-specific helpers:**
- ❌ Resource caching layer
- ❌ Tool chaining DSL
- ❌ Prompt composition helpers
- **Trigger:** Common patterns emerge across users

**Batch operations:**
- ❌ `Tools.call_many/2` for parallel tool execution
- ❌ `Resources.read_many/2` for batched reads
- **Trigger:** Performance optimization for high-volume calls

## Examples

### Basic Usage

```elixir
# Start connection
{:ok, conn} = MCPClient.start_link(
  transport: {MCPClient.Transports.Stdio,
              cmd: "uvx",
              args: ["mcp-server-sqlite", "--db-path", "test.db"]}
)

# List available tools
{:ok, tools} = MCPClient.Tools.list(conn)
# [%MCPClient.Tools.Tool{name: "read_query", description: "Execute SELECT", ...}]

# Call a tool
{:ok, result} = MCPClient.Tools.call(conn, "read_query", %{
  query: "SELECT * FROM users LIMIT 10"
})
# %MCPClient.Tools.CallResult{content: [...], isError: false}

# Read a resource
{:ok, contents} = MCPClient.Resources.read(conn, "file:///path/to/file.txt")

# Subscribe to resource updates
:ok = MCPClient.Resources.subscribe(conn, "file:///path/to/file.txt")
```

### With Notification Handling

```elixir
{:ok, conn} = MCPClient.start_link(
  transport: {MCPClient.Transports.Stdio, cmd: "mcp-server"},
  notification_handler: fn notification ->
    case MCPClient.NotificationRouter.route(notification) do
      {:resources, :updated, %{"uri" => uri}} ->
        Logger.info("Resource updated: #{uri}")
        MyApp.handle_resource_change(uri)

      {:tools, :list_changed, _params} ->
        Logger.info("Tools changed, refreshing...")
        Task.start(fn -> refresh_tool_list(conn) end)

      _ -> :ok
    end
  end
)
```

### Error Handling

```elixir
case MCPClient.Tools.call(conn, "nonexistent_tool", %{}) do
  {:ok, result} ->
    process_result(result)

  {:error, %MCPClient.Error{type: :method_not_found, message: msg}} ->
    Logger.warn("Tool not found: #{msg}")

  {:error, %MCPClient.Error{type: :timeout}} ->
    Logger.error("Tool call timed out")
    retry_or_fail()

  {:error, %MCPClient.Error{} = error} ->
    Logger.error("Tool call failed: #{inspect(error)}")
end
```

## References

- **ADR-0010**: MVP Scope and Deferrals - defines feature boundaries
- **ADR-0001**: gen_statem - core state machine (what features build on)
- **ADR-0006**: Synchronous notification handlers - how server notifications work
- **MCP Specification**: https://spec.modelcontextprotocol.io/
  - Protocol primitives: Tools, Resources, Prompts, Sampling, Roots
- **Elixir Patterns**:
  - Ecto modules (Repo, Query, Schema, Changeset)
  - Req modules (get, post, request)
  - Phoenix modules (Channel, Socket, PubSub)

## Verification

Feature architecture is correct if:

1. ✅ Each feature module only calls `Connection.call/4` and `Connection.notify/3`
2. ✅ Core modules never import/alias feature modules (one-way dependency)
3. ✅ Each feature can be tested with a mock connection (no real transport needed)
4. ✅ Adding new features requires no changes to core
5. ✅ All errors are normalized through `MCPClient.Error`
6. ✅ Notification routing works without modifying core
7. ✅ API feels natural to Elixir developers (positive user feedback)

---

**Implementation Status**: Ready for implementation after PROMPT_01-09 complete
**Next Step**: Validate core API surface during PROMPT_07 (Public API Module)
