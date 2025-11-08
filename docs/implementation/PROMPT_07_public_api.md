# Implementation Prompt 07: Public API Module

**Goal:** Create the public API module (McpClient) with high-level functions for starting connections, making requests, and managing the client.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the user-facing API that wraps the Connection state machine. This provides:
1. **Connection lifecycle**: `start_link/1`, `stop/1`
2. **MCP operations**: `call_tool/3`, `list_tools/1`, `list_resources/1`, etc.
3. **Configuration**: Simple keyword list interface
4. **Error handling**: Normalized error returns

Users will interact with this module, not directly with Connection.

---

## Required Reading: API Specification

From MVP_SPEC.md and ADRs:

### Supported MCP Methods (MVP Scope)

**Tools:**
- `tools/list` → `list_tools/1`
- `tools/call` → `call_tool/3`

**Resources:**
- `resources/list` → `list_resources/1`
- `resources/read` → `read_resource/2`
- `resources/templates/list` → `list_resource_templates/1`

**Prompts:**
- `prompts/list` → `list_prompts/1`
- `prompts/get` → `get_prompt/2`

**General:**
- `ping` → `ping/1`
- `initialize` → (internal, handled by Connection)

### Configuration Options

```elixir
[
  # Transport
  transport: :stdio,              # Required: :stdio (MVP)
  command: "npx",                 # Required for :stdio
  args: ["-y", "@modelcontextprotocol/server-everything"],
  env: [],                        # Optional environment variables
  name: {:via, Registry, {MyApp.MCP.Registry, term()}}, # Required for supervised use

  # Timeouts
  request_timeout: 30_000,        # Default: 30 seconds
  init_timeout: 10_000,           # Default: 10 seconds

  # Backoff
  backoff_min: 1_000,             # Default: 1 second
  backoff_max: 30_000,            # Default: 30 seconds

  # Retry
  retry_attempts: 3,              # Default: 3 attempts
  retry_delay_ms: 10,             # Default: 10ms base delay
  retry_jitter: 0.5,              # Default: ±50% jitter

  # Notifications
  notification_handlers: [fun],   # Default: []

  # Advanced
  max_frame_bytes: 16_777_216,    # Default: 16MB
  tombstone_sweep_ms: 60_000,     # Default: 60 seconds
  stateless_supervisor: McpClient.StatelessSupervisor # Override isolated-task supervisor
]
```

All public helpers should ensure a registered name exists. If the caller omits `:name`, default to `{:via, Registry, {McpClient.ConnectionRegistry, System.unique_integer()}}` so downstream transports can resolve the Connection even in multi-client deployments.

### Return Values

**Success:**
```elixir
{:ok, result}  # result is map with response data
```

**Errors (from ADR-0009 and MVP_SPEC.md):**
```elixir
{:error, %McpClient.Error{
  type: :transport | :timeout | :unavailable | :shutdown | :server,
  message: String.t(),
  details: map()
}}
```

---

## Implementation Requirements

### 1. Error Struct

**File: `lib/mcp_client/error.ex`**

```elixir
defmodule McpClient.Error do
  @moduledoc """
  Error struct for MCP client operations.

  ## Error Types

  - `:transport` - Transport-level failure (connection down, send failed)
  - `:timeout` - Request timeout
  - `:unavailable` - Connection in backoff, not ready
  - `:shutdown` - Connection is shutting down
  - `:server` - Server returned JSON-RPC error
  - `:protocol` - Protocol violation (invalid response shape)
  """

  @type t :: %__MODULE__{
    type: :transport | :timeout | :unavailable | :shutdown | :server | :protocol,
    message: String.t(),
    details: map()
  }

defstruct [:type, :message, details: %{}]
end
```

### 2. Public API Module

**File: `lib/mcp_client.ex`**

```elixir
defmodule McpClient do
  @moduledoc """
  Public API for the MCP (Model Context Protocol) client.

  ## Usage

      {:ok, client} = McpClient.start_link(
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-everything"]
      )

      {:ok, tools} = McpClient.list_tools(client)
      {:ok, result} = McpClient.call_tool(client, "get_weather", %{"city" => "NYC"})

      :ok = McpClient.stop(client)

  ## Configuration

  See module documentation for full list of configuration options.

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, %McpClient.Error{}}`.
  """

  alias McpClient.{Connection, ConnectionSupervisor, Error}

  @type client :: pid() | atom()
  @type result :: {:ok, term()} | {:error, Error.t()}

  ## Lifecycle

  @doc """
  Start an MCP client connection.

  ## Options

  - `:transport` - (required) Transport type, `:stdio` for MVP
  - `:command` - (required for stdio) Command to execute
  - `:args` - Command arguments (default: [])
  - `:env` - Environment variables (default: [])
  - `:name` - Registered name (atom or `{:via, Registry, ...}`); default to ConnectionRegistry slot if omitted
  - `:request_timeout` - Request timeout in ms (default: 30_000)
  - `:init_timeout` - Initialize timeout in ms (default: 10_000)
  - `:backoff_min` - Minimum backoff delay in ms (default: 1_000)
  - `:backoff_max` - Maximum backoff delay in ms (default: 30_000)
  - `:notification_handlers` - List of notification handler functions (default: [])
  - `:stateless_supervisor` - Optional `{module, term}` to override Task.Supervisor for stateless tool executions

  ## Examples

      {:ok, client} = McpClient.start_link(
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-everything"]
      )

      {:ok, client} = McpClient.start_link(
        transport: :stdio,
        command: "python",
        args: ["server.py"],
        name: :my_mcp_client,
        request_timeout: 60_000
      )
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    # Start the supervisor which starts Transport and Connection
    ConnectionSupervisor.start_link(opts)
  end

  @doc """
  Stop the MCP client connection gracefully.

  Fails all in-flight requests and closes the transport.

  ## Examples

      :ok = McpClient.stop(client)
  """
  @spec stop(client()) :: :ok
  def stop(client) do
    # Call Connection stop (returns :ok, not {:ok, :ok})
    :gen_statem.call(client, :stop)
  end

  ## Tools API

  @doc """
  List available tools from the server.

  ## Examples

      {:ok, tools} = McpClient.list_tools(client)
      # => {:ok, %{"tools" => [%{"name" => "get_weather", ...}]}}
  """
  @spec list_tools(client(), keyword()) :: result()
  def list_tools(client, opts \\ []) do
    request(client, "tools/list", %{}, opts)
  end

  @doc """
  Call a tool on the server.

  ## Examples

      {:ok, result} = McpClient.call_tool(client, "get_weather", %{"city" => "NYC"})
      # => {:ok, %{"temperature" => 72, "condition" => "sunny"}}
  """
  @spec call_tool(client(), String.t(), map(), keyword()) :: result()
  def call_tool(client, name, arguments, opts \\ []) do
    params = %{
      "name" => name,
      "arguments" => arguments
    }
    request(client, "tools/call", params, opts)
  end

  ## Resources API

  @doc """
  List available resources from the server.

  ## Examples

      {:ok, resources} = McpClient.list_resources(client)
      # => {:ok, %{"resources" => [%{"uri" => "file:///path/to/file", ...}]}}
  """
  @spec list_resources(client(), keyword()) :: result()
  def list_resources(client, opts \\ []) do
    request(client, "resources/list", %{}, opts)
  end

  @doc """
  Read a resource from the server.

  ## Examples

      {:ok, content} = McpClient.read_resource(client, "file:///path/to/file")
      # => {:ok, %{"contents" => [%{"text" => "..."}]}}
  """
  @spec read_resource(client(), String.t(), keyword()) :: result()
  def read_resource(client, uri, opts \\ []) do
    params = %{"uri" => uri}
    request(client, "resources/read", params, opts)
  end

  @doc """
  List available resource templates from the server.

  ## Examples

      {:ok, templates} = McpClient.list_resource_templates(client)
  """
  @spec list_resource_templates(client(), keyword()) :: result()
  def list_resource_templates(client, opts \\ []) do
    request(client, "resources/templates/list", %{}, opts)
  end

  ## Prompts API

  @doc """
  List available prompts from the server.

  ## Examples

      {:ok, prompts} = McpClient.list_prompts(client)
      # => {:ok, %{"prompts" => [%{"name" => "summarize", ...}]}}
  """
  @spec list_prompts(client(), keyword()) :: result()
  def list_prompts(client, opts \\ []) do
    request(client, "prompts/list", %{}, opts)
  end

  @doc """
  Get a prompt from the server.

  ## Examples

      {:ok, prompt} = McpClient.get_prompt(client, "summarize", %{"text" => "..."})
  """
  @spec get_prompt(client(), String.t(), map(), keyword()) :: result()
  def get_prompt(client, name, arguments \\ %{}, opts \\ []) do
    params = %{
      "name" => name,
      "arguments" => arguments
    }
    request(client, "prompts/get", params, opts)
  end

  ## General

  @doc """
  Ping the server.

  ## Examples

      {:ok, _} = McpClient.ping(client)
      # => {:ok, %{}}
  """
  @spec ping(client(), keyword()) :: result()
  def ping(client, opts \\ []) do
    request(client, "ping", %{}, opts)
  end

  ## Helpers

  defp request(client, method, params, opts) do
    case :gen_statem.call(client, {:request, method, params, opts}) do
      {:ok, _request_id} ->
        # Connection replied with request ID, but we're doing sync call
        # so we'll receive the actual response via reply mechanism
        # Wait for the actual response (this is handled by gen_statem call)
        # Actually, we need to rethink this...

        # The issue is that Connection.handle_event replies with {:ok, id}
        # but the actual response comes later via GenServer.reply

        # We need Connection to store caller and reply later, OR
        # we need a different call structure

        # Let's fix this: Connection should NOT reply with {:ok, id} for
        # the sync call case. Instead, it should store the caller and
        # reply when response arrives.

        receive do
          {:ok, result} -> {:ok, result}
          {:error, error} -> {:error, normalize_error(error)}
        end

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(%{"code" => code, "message" => message}) do
    # JSON-RPC error from server
    %Error{
      type: :server,
      message: message,
      details: %{code: code}
    }
  end

  defp normalize_error(%{type: type, message: message} = map) do
    # Error from Connection (already structured)
    %Error{
      type: type,
      message: message,
      details: Map.get(map, :details, %{})
    }
  end

  defp normalize_error(other) do
    # Unknown error shape
    %Error{
      type: :protocol,
      message: "Unexpected error: #{inspect(other)}",
      details: %{raw: other}
    }
  end
end
```

**NOTE**: The above implementation has an issue with the request flow. We need to fix the Connection to support synchronous requests properly. See "Implementation Notes" below.

---

## Connection API Update

The current Connection implementation replies with `{:ok, request_id}` immediately, then later replies to the stored `from` with the result. This doesn't work well with synchronous public API.

**Two options:**

### Option 1: Keep Async, Add Wrapper

Connection stays as-is (async with request IDs). McpClient tracks requests:

```elixir
defp request(client, method, params, opts) do
  timeout = Keyword.get(opts, :timeout, 30_000)

  case :gen_statem.call(client, {:request, method, params, opts}, timeout + 1000) do
    {:ok, _request_id} ->
      # Wait for actual response (comes via stored `from`)
      receive do
        {^ref, response} -> normalize_response(response)
      after
        timeout -> {:error, %Error{type: :timeout, message: "Request timeout"}}
      end

    {:error, error} ->
      {:error, normalize_error(error)}
  end
end
```

**Problem**: This requires Connection to reply to the same `from` twice, which gen_statem doesn't support cleanly.

### Option 2: Synchronous Request Mode (RECOMMENDED)

Add a `:sync` option to Connection that makes it reply with the final result instead of request ID:

```elixir
# In Connection:
def handle_event({:call, from}, {:request, method, params, opts}, :ready, data) do
  sync = Keyword.get(opts, :sync, true)  # Default to sync for public API

  # ... (existing logic to send frame)

  if sync do
    # Don't reply immediately, store `from` in request
    # Reply when response arrives or timeout occurs
    request = %{from: from, ...}
    # Don't include {:reply, from, {:ok, id}} in actions
  else
    # Async mode: reply with request ID immediately
    {:reply, from, {:ok, id}}
  end
end
```

This is cleaner and matches user expectations for synchronous API.

**For MVP, use Option 2 (synchronous by default).**

---

## Test File: test/mcp_client_test.exs

```elixir
defmodule McpClientTest do
  use ExUnit.Case, async: true

  describe "start_link/1" do
    test "starts connection successfully" do
      {:ok, client} = McpClient.start_link(
        transport: :mock,
        command: "test"
      )

      assert Process.alive?(client)
      McpClient.stop(client)
    end

    test "returns error for invalid configuration" do
      # Missing required command
      assert {:error, _} = McpClient.start_link(transport: :stdio)
    end
  end

  describe "stop/1" do
    test "stops connection gracefully" do
      {:ok, client} = McpClient.start_link(transport: :mock, command: "test")
      assert :ok = McpClient.stop(client)
      refute Process.alive?(client)
    end
  end

  describe "list_tools/1" do
    setup do
      {:ok, client} = start_mock_client()
      {:ok, client: client}
    end

    test "returns list of tools", %{client: client} do
      # Mock server response
      mock_response = %{
        "tools" => [
          %{"name" => "get_weather", "description" => "Get weather"}
        ]
      }

      # Send response manually (need better mock setup)
      # For now, just test compilation

      assert {:ok, _} = McpClient.list_tools(client)
    end
  end

  describe "call_tool/3" do
    setup do
      {:ok, client} = start_mock_client()
      {:ok, client: client}
    end

    test "calls tool with arguments", %{client: client} do
      result = McpClient.call_tool(client, "get_weather", %{"city" => "NYC"})

      # Should return result (test with real mock)
      assert {:ok, _} = result
    end

    test "returns error on server error", %{client: client} do
      # Mock server error response
      # Test error normalization
    end
  end

  describe "error normalization" do
    test "normalizes server JSON-RPC errors" do
      error = %{"code" => -32601, "message" => "Method not found"}
      normalized = normalize_error(error)

      assert %McpClient.Error{
        type: :server,
        message: "Method not found",
        details: %{code: -32601}
      } = normalized
    end

    test "normalizes transport errors" do
      error = %{type: :transport, message: "Connection lost"}
      normalized = normalize_error(error)

      assert %McpClient.Error{type: :transport} = normalized
    end
  end

  defp start_mock_client do
    McpClient.start_link(transport: :mock, command: "test")
  end

  # Helper to access private normalize_error (for testing)
  defp normalize_error(error) do
    # Use send/receive to test via public API
    # Or make normalize_error public for testing
  end
end
```

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client_test.exs
```

**Must achieve:**
- ✅ All tests pass (green)
- ✅ No warnings
- ✅ Public API compiles
- ✅ Synchronous requests work
- ✅ Error normalization works
- ✅ All MCP methods exposed

---

## Constraints

- **DO NOT** implement cancellation API yet (post-MVP)
- **DO NOT** add methods beyond MVP scope
- Synchronous API only (no async variants)
- All timeouts in milliseconds
- Error struct must have exact fields

---

## Implementation Notes

### Synchronous Request Flow

**Recommended approach for MVP:**

1. Public API calls `request(client, method, params, opts)`
2. `request/4` calls `:gen_statem.call(client, {:request, ...}, timeout)`
3. Connection does NOT reply with `{:ok, id}` immediately
4. Connection stores `from` in request struct
5. When response arrives, Connection replies with `{:ok, result}` or `{:error, error}`
6. gen_statem call returns to public API with final result

**Connection changes needed:**
- Remove `{:reply, from, {:ok, id}}` from send_frame success case
- Store `from` in request struct
- Reply in `handle_response/3` and timeout handler

### Supervisor Integration

The `start_link/1` should start `ConnectionSupervisor`, which starts both Transport and Connection. Update Connection Supervisor if needed:

```elixir
defmodule McpClient.ConnectionSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init(opts) do
    connection_pid = self()  # Will be supervisor PID initially

    # Need to handle this differently - Connection needs to know its own PID
    # after startup...

    # Better approach: Start Transport with `connection: :via` or registry
    # OR: Start Connection first, then Transport with Connection's PID

    # For MVP, simplify: Just start Connection directly, no supervisor
    # Supervisor comes in post-MVP for resilience
  end
end
```

**For MVP**: Skip supervisor complexity, just start Connection directly:

```elixir
def start_link(opts) do
  Connection.start_link(opts)
end
```

Post-MVP can add supervision.

### Notification Handlers

Stored in `data.notification_handlers` (list of functions). Users pass them via `start_link`:

```elixir
handler = fn notification ->
  IO.puts("Received: #{inspect(notification)}")
end

{:ok, client} = McpClient.start_link(
  transport: :stdio,
  command: "server",
  notification_handlers: [handler]
)
```

### Error Details

Include context in `details` map:
- `:transport` errors: `%{reason: term()}`
- `:server` errors: `%{code: integer()}`
- `:unavailable` errors: `%{backoff_delay_ms: integer()}`

---

## Deliverable

Provide:
1. `lib/mcp_client/error.ex` - Error struct
2. `lib/mcp_client.ex` - Public API
3. Update `lib/mcp_client/connection.ex` - Add synchronous request support
4. `test/mcp_client_test.exs` - API tests

All files must:
- Compile without warnings
- Pass all tests
- Provide clean, synchronous API
- Handle errors gracefully

If any requirement is unclear, insert `# TODO: <reason>` and stop.
