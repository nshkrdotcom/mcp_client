# Error Handling Guide

Comprehensive guide to handling errors in MCP Client applications.

---

## Overview

MCP Client uses structured error handling with the `MCPClient.Error` struct. All operations return:
- `{:ok, result}` on success
- `{:error, %MCPClient.Error{}}` on failure

This guide covers error types, handling patterns, recovery strategies, and best practices.

---

## Error Structure

```elixir
%MCPClient.Error{
  type: :timeout,                    # Error type (atom)
  message: "Request timed out",      # Human-readable message
  operation: :tools_call,            # Operation that failed (atom)
  details: %{...},                   # Additional context (map)
  server_error: %{                   # Original server error (if applicable)
    code: -32601,
    message: "Method not found",
    data: %{...}
  }
}
```

---

## Error Types

### Connection Errors

**`:timeout`** - Request or operation exceeded timeout

```elixir
{:error, %Error{type: :timeout, operation: :tools_list}}
```

**When it occurs:**
- Request takes longer than `request_timeout`
- Initialize handshake exceeds `init_timeout`
- Operation doesn't complete in time

**How to handle:**
```elixir
case MCPClient.Tools.call(conn, "slow_tool", %{}) do
  {:ok, result} ->
    {:ok, result}

  {:error, %Error{type: :timeout}} ->
    # Retry with longer timeout
    MCPClient.Tools.call(conn, "slow_tool", %{}, timeout: 60_000)
end
```

**`:connection_closed`** - Connection to server lost

```elixir
{:error, %Error{type: :connection_closed}}
```

**When it occurs:**
- Server process crashed
- Network connection lost
- Transport closed unexpectedly

**How to handle:**
```elixir
case MCPClient.Tools.list(conn) do
  {:ok, tools} ->
    {:ok, tools}

  {:error, %Error{type: :connection_closed}} ->
    # Connection will automatically reconnect
    # Wait and retry, or fail gracefully
    Logger.warn("Connection lost, will reconnect automatically")
    {:error, :temporarily_unavailable}
end
```

**Note:** Connection automatically reconnects with exponential backoff. You can retry after a delay or fail gracefully.

**`:transport_error`** - Transport-level error

```elixir
{:error, %Error{type: :transport_error, details: %{reason: :econnrefused}}}
```

**When it occurs:**
- Network error (connection refused, host unreachable)
- Transport-specific failure (port died, HTTP error)

---

### Protocol Errors

**`:parse_error`** - Invalid JSON received

```elixir
{:error, %Error{type: :parse_error}}
```

**When it occurs:**
- Server sent malformed JSON
- Binary corruption in transit

**`:invalid_request`** - Malformed JSON-RPC request

```elixir
{:error, %Error{type: :invalid_request}}
```

**When it occurs:**
- Missing required JSON-RPC fields
- Invalid request structure

**`:invalid_response`** - Server returned unexpected response

```elixir
{:error, %Error{type: :invalid_response}}
```

**When it occurs:**
- Response missing expected fields
- Response structure doesn't match schema
- Type mismatch in response data

**How to handle:**
```elixir
case MCPClient.Resources.read(conn, uri) do
  {:ok, contents} ->
    {:ok, contents}

  {:error, %Error{type: :invalid_response}} ->
    # Log for debugging
    Logger.error("Server returned invalid response for #{uri}")
    # Update server or report bug
    {:error, :server_bug}
end
```

**`:decode_error`** - JSON decode failure

```elixir
{:error, %Error{type: :decode_error}}
```

**When it occurs:**
- JSON is syntactically valid but semantically invalid
- Character encoding issues

**`:oversized_frame`** - Frame exceeded size limit

```elixir
{:error, %Error{type: :oversized_frame}}
```

**When it occurs:**
- Server sent frame > `max_frame_bytes` (default 16MB)
- Connection is closed after this error

**How to handle:**
```elixir
case MCPClient.Resources.read(conn, huge_file_uri) do
  {:error, %Error{type: :oversized_frame}} ->
    Logger.error("Resource too large: #{huge_file_uri}")
    # Options:
    # 1. Increase max_frame_bytes (risky)
    # 2. Request pagination/chunking from server
    # 3. Use alternative access method
    {:error, :resource_too_large}
end
```

---

### MCP-Specific Errors

**`:method_not_found`** - Server doesn't recognize method

```elixir
{:error, %Error{type: :method_not_found, server_error: %{code: -32601}}}
```

**When it occurs:**
- Calling unsupported MCP method
- Server doesn't implement feature
- Method name typo

**How to handle:**
```elixir
# Check capabilities first
caps = MCPClient.server_capabilities(conn)

if has_capability?(caps, [:resources, :subscribe]) do
  MCPClient.Resources.subscribe(conn, uri)
else
  Logger.warn("Server doesn't support subscriptions")
  # Fall back to polling
  poll_resource(conn, uri)
end
```

**`:invalid_params`** - Invalid method parameters

```elixir
{:error, %Error{type: :invalid_params, server_error: %{code: -32602}}}
```

**When it occurs:**
- Missing required parameters
- Wrong parameter types
- Parameter validation failed

**How to handle:**
```elixir
case MCPClient.Tools.call(conn, "search", params) do
  {:ok, result} ->
    {:ok, result}

  {:error, %Error{type: :invalid_params} = error} ->
    Logger.error("Invalid parameters: #{inspect(params)}")
    Logger.error("Server error: #{error.server_error["message"]}")
    # Fix parameters and retry
    {:error, :bad_request}
end
```

**`:internal_error`** - Server internal error

```elixir
{:error, %Error{type: :internal_error, server_error: %{code: -32603}}}
```

**When it occurs:**
- Server bug/crash
- Server resource exhaustion
- Uncaught server exception

**How to handle:**
```elixir
case MCPClient.Tools.call(conn, "buggy_tool", %{}) do
  {:error, %Error{type: :internal_error} = error} ->
    # Log for server maintainer
    Logger.error("Server error: #{error.server_error["message"]}")
    # Report to server maintainers
    report_server_error(error)
    {:error, :server_error}
end
```

**`:tool_not_found`** - Tool doesn't exist

```elixir
{:error, %Error{type: :tool_not_found}}
```

**When it occurs:**
- Tool name doesn't exist on server
- Typo in tool name

**How to handle:**
```elixir
# Validate tool exists first
{:ok, tools} = MCPClient.Tools.list(conn)
tool_names = Enum.map(tools, & &1.name)

if tool_name in tool_names do
  MCPClient.Tools.call(conn, tool_name, args)
else
  Logger.error("Tool '#{tool_name}' not found. Available: #{inspect(tool_names)}")
  {:error, :tool_not_found}
end
```

**`:tool_execution_failed`** - Tool ran but returned error

```elixir
{:error, %Error{type: :tool_execution_failed}}
```

**When it occurs:**
- Tool executed but failed internally
- Tool returned `isError: true`

**How to handle:**
```elixir
case MCPClient.Tools.call(conn, "read_file", %{path: "/missing"}) do
  {:ok, %{isError: true, content: content}} ->
    # Tool ran but reported error
    error_msg = Enum.find_value(content, fn
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
    Logger.warn("Tool error: #{error_msg}")
    {:error, :tool_failed}

  {:ok, result} ->
    {:ok, result}
end
```

**`:resource_not_found`** - Resource doesn't exist

```elixir
{:error, %Error{type: :resource_not_found}}
```

**`:resource_not_readable`** - Resource exists but can't be read

```elixir
{:error, %Error{type: :resource_not_readable}}
```

**`:prompt_not_found`** - Prompt doesn't exist

```elixir
{:error, %Error{type: :prompt_not_found}}
```

**`:sampling_not_supported`** - Server can't perform sampling

```elixir
{:error, %Error{type: :sampling_not_supported}}
```

**`:capability_not_supported`** - Feature not supported

```elixir
{:error, %Error{type: :capability_not_supported}}
```

---

## Error Handling Patterns

### Basic Pattern Matching

```elixir
case MCPClient.Tools.call(conn, tool_name, args) do
  {:ok, result} ->
    process_result(result)

  {:error, %MCPClient.Error{type: :timeout}} ->
    retry_with_longer_timeout()

  {:error, %MCPClient.Error{type: :tool_not_found}} ->
    {:error, :invalid_tool}

  {:error, %MCPClient.Error{type: :connection_closed}} ->
    {:error, :temporarily_unavailable}

  {:error, error} ->
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, :unknown}
end
```

### Retry with Backoff

```elixir
defmodule MyApp.MCP do
  def call_tool_with_retry(conn, name, args, max_attempts \\ 3) do
    call_tool_with_retry(conn, name, args, 1, max_attempts)
  end

  defp call_tool_with_retry(conn, name, args, attempt, max_attempts) do
    case MCPClient.Tools.call(conn, name, args) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{type: type}} when type in [:timeout, :connection_closed]
                                        and attempt < max_attempts ->
        # Exponential backoff
        delay = :math.pow(2, attempt) * 100 |> round()
        Logger.warn("Attempt #{attempt} failed, retrying in #{delay}ms...")
        Process.sleep(delay)
        call_tool_with_retry(conn, name, args, attempt + 1, max_attempts)

      {:error, error} ->
        {:error, error}
    end
  end
end
```

### Fallback Strategies

```elixir
def get_data(conn, source) do
  case MCPClient.Resources.read(conn, source) do
    {:ok, data} ->
      {:ok, data}

    {:error, %Error{type: :resource_not_found}} ->
      # Try alternative source
      Logger.info("Primary source unavailable, trying backup...")
      get_data_from_backup(source)

    {:error, %Error{type: :connection_closed}} ->
      # Use cached data
      Logger.warn("Connection lost, using cached data")
      {:ok, get_cached_data(source)}

    {:error, error} ->
      {:error, error}
  end
end
```

### Capability Checking

```elixir
def subscribe_or_poll(conn, uri) do
  caps = MCPClient.server_capabilities(conn)

  if supports_subscription?(caps) do
    case MCPClient.Resources.subscribe(conn, uri) do
      :ok ->
        {:ok, :subscribed}
      {:error, error} ->
        Logger.warn("Subscription failed: #{inspect(error)}, falling back to polling")
        start_polling(conn, uri)
    end
  else
    Logger.info("Server doesn't support subscriptions, using polling")
    start_polling(conn, uri)
  end
end

defp supports_subscription?(caps) do
  get_in(caps, ["resources", "subscribe"]) != nil
end
```

### Circuit Breaker

```elixir
defmodule MyApp.CircuitBreaker do
  use GenServer

  # States: :closed (normal), :open (failing), :half_open (testing)
  defstruct [:state, :failure_count, :last_failure, :threshold, :timeout]

  def call_with_breaker(breaker, fun) do
    case get_state(breaker) do
      :open ->
        {:error, :circuit_open}

      state when state in [:closed, :half_open] ->
        case fun.() do
          {:ok, _} = success ->
            record_success(breaker)
            success

          {:error, %MCPClient.Error{}} = error ->
            record_failure(breaker)
            error
        end
    end
  end

  defp record_failure(breaker) do
    GenServer.cast(breaker, :failure)
  end

  defp record_success(breaker) do
    GenServer.cast(breaker, :success)
  end

  # Implementation details omitted for brevity
end

# Usage:
CircuitBreaker.call_with_breaker(MyApp.MCPBreaker, fn ->
  MCPClient.Tools.call(conn, "unreliable_tool", %{})
end)
```

### Error Aggregation

```elixir
defmodule MyApp.ErrorTracker do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def track_error(operation, error) do
    Agent.update(__MODULE__, fn state ->
      key = {operation, error.type}
      Map.update(state, key, 1, &(&1 + 1))
    end)
  end

  def get_stats do
    Agent.get(__MODULE__, & &1)
  end
end

# Usage:
case MCPClient.Tools.call(conn, tool, args) do
  {:ok, result} ->
    {:ok, result}

  {:error, error} ->
    MyApp.ErrorTracker.track_error(:tools_call, error)
    {:error, error}
end

# Periodic review:
defmodule MyApp.ErrorReporter do
  use GenServer

  def init(_) do
    schedule_report()
    {:ok, %{}}
  end

  def handle_info(:report, state) do
    stats = MyApp.ErrorTracker.get_stats()

    # Find most common errors
    top_errors = stats
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(10)

    Logger.warn("Top MCP errors: #{inspect(top_errors)}")

    schedule_report()
    {:noreply, state}
  end

  defp schedule_report do
    Process.send_after(self(), :report, :timer.hours(1))
  end
end
```

---

## Recovery Strategies

### Automatic Reconnection

Connection automatically reconnects on failure:

```elixir
# Connection lost
{:error, %Error{type: :connection_closed}}

# Wait briefly (connection is reconnecting)
Process.sleep(1000)

# Retry operation
case MCPClient.Tools.list(conn) do
  {:ok, tools} ->
    # Reconnected successfully
    {:ok, tools}

  {:error, %Error{type: :connection_closed}} ->
    # Still reconnecting, wait longer or fail
    {:error, :unavailable}
end
```

### Graceful Degradation

```elixir
def get_tools(conn) do
  case MCPClient.Tools.list(conn) do
    {:ok, tools} ->
      {:ok, tools}

    {:error, %Error{type: :timeout}} ->
      # Use cached tools if available
      case get_cached_tools() do
        {:ok, tools} ->
          Logger.warn("Using cached tools due to timeout")
          {:ok, tools}

        :error ->
          # Return empty list as last resort
          Logger.error("No cached tools available")
          {:ok, []}
      end

    {:error, error} ->
      Logger.error("Failed to get tools: #{inspect(error)}")
      {:ok, []}  # Degrade to empty list
  end
end
```

### User Notification

```elixir
def execute_tool(conn, tool_name, args) do
  case MCPClient.Tools.call(conn, tool_name, args) do
    {:ok, result} ->
      {:ok, result}

    {:error, %Error{type: :timeout}} ->
      # User-friendly message
      {:error, "The operation is taking longer than expected. Please try again later."}

    {:error, %Error{type: :tool_not_found}} ->
      {:error, "The tool '#{tool_name}' is not available."}

    {:error, %Error{type: :connection_closed}} ->
      {:error, "Connection to server lost. Reconnecting..."}

    {:error, %Error{type: :internal_error, server_error: server_err}} ->
      # Include server error message
      {:error, "Server error: #{server_err["message"]}"}

    {:error, error} ->
      # Generic fallback
      {:error, "An error occurred: #{error.message}"}
  end
end
```

### Logging Best Practices

```elixir
defmodule MyApp.MCP.ErrorLogger do
  require Logger

  def log_error(error, context \\ %{}) do
    case error.type do
      # Expected errors - warn level
      type when type in [:timeout, :connection_closed] ->
        Logger.warn(format_error(error, context))

      # User errors - info level
      type when type in [:tool_not_found, :resource_not_found, :invalid_params] ->
        Logger.info(format_error(error, context))

      # Server/system errors - error level
      type when type in [:internal_error, :parse_error, :oversized_frame] ->
        Logger.error(format_error(error, context))

      # Unknown - error level
      _ ->
        Logger.error(format_error(error, context))
    end
  end

  defp format_error(error, context) do
    """
    MCP Error: #{error.type}
    Operation: #{error.operation}
    Message: #{error.message}
    Context: #{inspect(context)}
    Details: #{inspect(error.details)}
    Server Error: #{inspect(error.server_error)}
    """
  end
end

# Usage:
case MCPClient.Tools.call(conn, tool, args) do
  {:ok, result} ->
    {:ok, result}

  {:error, error} ->
    MyApp.MCP.ErrorLogger.log_error(error, %{
      tool: tool,
      args: args,
      user_id: user_id
    })
    {:error, error}
end
```

---

## Testing Error Handling

### Unit Tests

```elixir
defmodule MyApp.ToolExecutorTest do
  use ExUnit.Case
  alias MCPClient.Error

  describe "execute_tool/3" do
    test "handles timeout errors" do
      # Mock connection that times out
      conn = mock_conn_with_error({:error, %Error{type: :timeout}})

      assert {:error, msg} = MyApp.ToolExecutor.execute_tool(conn, "tool", %{})
      assert msg =~ "longer than expected"
    end

    test "handles tool not found" do
      conn = mock_conn_with_error({:error, %Error{type: :tool_not_found}})

      assert {:error, msg} = MyApp.ToolExecutor.execute_tool(conn, "missing", %{})
      assert msg =~ "not available"
    end

    test "retries on connection closed" do
      # First call fails, second succeeds
      conn = mock_conn_with_retry()

      assert {:ok, result} = MyApp.ToolExecutor.execute_tool(conn, "tool", %{})
    end
  end
end
```

### Integration Tests

```elixir
@tag :integration
test "handles real server errors" do
  {:ok, conn} = MCPClient.start_link(
    transport: {MCPClient.Transports.Stdio, cmd: "test-server"}
  )

  # Call non-existent tool
  assert {:error, %Error{type: :tool_not_found}} =
    MCPClient.Tools.call(conn, "nonexistent", %{})

  # Call tool with invalid params
  assert {:error, %Error{type: :invalid_params}} =
    MCPClient.Tools.call(conn, "search", %{invalid: "param"})

  MCPClient.stop(conn)
end
```

---

## Production Monitoring

### Error Metrics

```elixir
defmodule MyApp.MCP.Telemetry do
  require Logger

  def handle_event([:mcp_client, :error], %{count: 1}, metadata, _config) do
    # Increment error counter by type
    :telemetry.execute(
      [:myapp, :mcp, :error],
      %{count: 1},
      %{type: metadata.error_type, operation: metadata.operation}
    )

    # Log to external monitoring (Datadog, Honeycomb, etc.)
    log_to_monitoring(metadata)
  end

  defp log_to_monitoring(metadata) do
    # Send to monitoring service
    MyApp.Monitoring.log_event("mcp.error", metadata)
  end
end

# Attach handler
:telemetry.attach(
  "mcp-error-handler",
  [:mcp_client, :error],
  &MyApp.MCP.Telemetry.handle_event/4,
  nil
)
```

### Health Checks

```elixir
defmodule MyApp.MCP.HealthCheck do
  def check(conn) do
    case MCPClient.Connection.call(conn, "ping", %{}, 5_000) do
      {:ok, _} -> :healthy
      {:error, %Error{type: :timeout}} -> :degraded
      {:error, %Error{type: :connection_closed}} -> :unhealthy
      {:error, _} -> :unknown
    end
  end

  def periodic_check(conn) do
    case check(conn) do
      :healthy ->
        Logger.debug("MCP connection healthy")

      :degraded ->
        Logger.warn("MCP connection degraded (timeout)")
        alert_ops_team(:degraded)

      :unhealthy ->
        Logger.error("MCP connection unhealthy")
        alert_ops_team(:unhealthy)

      :unknown ->
        Logger.error("MCP connection status unknown")
        alert_ops_team(:unknown)
    end
  end
end
```

---

## Common Scenarios

### Handling Server Restarts

```elixir
# Connection will automatically reconnect, but in-flight requests fail
case MCPClient.Tools.call(conn, tool, args) do
  {:error, %Error{type: :connection_closed}} ->
    # Wait for reconnection (backoff handles this)
    Process.sleep(2000)

    # Retry once
    case MCPClient.Tools.call(conn, tool, args) do
      {:ok, result} -> {:ok, result}
      error -> error  # Give up
    end

  result -> result
end
```

### Handling Network Partitions

```elixir
def resilient_call(conn, method, params, opts \\ []) do
  max_wait = Keyword.get(opts, :max_wait, 30_000)
  start_time = System.monotonic_time(:millisecond)

  resilient_call_loop(conn, method, params, start_time, max_wait)
end

defp resilient_call_loop(conn, method, params, start_time, max_wait) do
  elapsed = System.monotonic_time(:millisecond) - start_time

  if elapsed > max_wait do
    {:error, :max_wait_exceeded}
  else
    case MCPClient.Connection.call(conn, method, params, 5000) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{type: type}} when type in [:timeout, :connection_closed] ->
        # Connection issues, wait and retry
        Process.sleep(1000)
        resilient_call_loop(conn, method, params, start_time, max_wait)

      {:error, error} ->
        # Other errors, fail immediately
        {:error, error}
    end
  end
end
```

---

## References

- [Getting Started](GETTING_STARTED.md) - Basic usage patterns
- [Configuration Guide](CONFIGURATION.md) - Timeout and retry configuration
- [Advanced Patterns](ADVANCED_PATTERNS.md) - Production patterns
- [Protocol Details](../design/PROTOCOL_DETAILS.md) - Error codes reference

---

**Need help?** Check [FAQ](FAQ.md) or open an issue on GitHub.
