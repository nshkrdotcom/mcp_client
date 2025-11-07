# PROMPT_10: Error and Notification Infrastructure

**Goal:** Implement `McpClient.Error` and `McpClient.NotificationRouter` modules to support client features.

**Duration:** ~30 minutes

**Dependencies:** PROMPT_01-09 (Core complete)

---

## Context

Before implementing high-level MCP feature APIs (Tools, Resources, etc.), we need shared infrastructure for:

1. **Error normalization** - Convert various error types into structured `McpClient.Error` structs
2. **Notification routing** - Route server-initiated notifications to typed callbacks

These modules provide the foundation for consistent error handling and notification dispatch across all feature modules.

---

## Required Reading

**ADR-0011:** Client Features Architecture
- Section: "Shared Infrastructure"
- Error normalization strategy
- Notification routing pattern

**PROTOCOL_DETAILS.md:**
- Section: "Error Codes" - JSON-RPC and MCP error codes
- Section: "Message Methods" - Notification methods

---

## Implementation Requirements

### 1. McpClient.Error Module

**File:** `lib/mcp_client/error.ex`

**Purpose:** Normalized error type for all MCP operations.

**Implementation:**

```elixir
defmodule McpClient.Error do
  @moduledoc """
  Normalized error type for MCP client operations.

  All feature modules convert errors to this struct for consistent handling.
  """

  use TypedStruct

  typedstruct do
    field :type, error_type(), enforce: true
    field :message, String.t(), enforce: true
    field :operation, atom()
    field :details, map()
    field :server_error, map()  # Original JSON-RPC error
  end

  @type error_type ::
    # JSON-RPC errors
    :parse_error
    | :invalid_request
    | :method_not_found
    | :invalid_params
    | :internal_error
    # MCP-specific errors
    | :resource_not_found
    | :resource_not_readable
    | :tool_not_found
    | :tool_execution_failed
    | :prompt_not_found
    | :sampling_not_supported
    | :capability_not_supported
    # Client-side errors
    | :timeout
    | :connection_closed
    | :invalid_response
    | :transport_error
    | :decode_error
    | :oversized_frame
    | :capability_mismatch
    | :unknown_error

  @doc """
  Normalize an error into structured McpClient.Error.

  ## Examples

      iex> Error.normalize(:timeout, :tools_list)
      %Error{type: :timeout, message: "Request timed out", operation: :tools_list}

      iex> Error.normalize({:jsonrpc_error, -32601, "Method not found", %{method: "foo"}}, :tools_call)
      %Error{
        type: :method_not_found,
        message: "Method not found",
        operation: :tools_call,
        server_error: %{code: -32601, message: "Method not found", data: %{method: "foo"}}
      }
  """
  @spec normalize(term(), atom()) :: t()
  def normalize(reason, operation)

  # Timeout
  def normalize(:timeout, operation) do
    %__MODULE__{
      type: :timeout,
      message: "Request timed out",
      operation: operation
    }
  end

  # Connection closed
  def normalize(:connection_closed, operation) do
    %__MODULE__{
      type: :connection_closed,
      message: "Connection closed",
      operation: operation
    }
  end

  def normalize({:connection_closed, reason}, operation) do
    %__MODULE__{
      type: :connection_closed,
      message: "Connection closed: #{inspect(reason)}",
      operation: operation,
      details: %{reason: reason}
    }
  end

  # JSON-RPC errors from server
  def normalize({:jsonrpc_error, code, message, data}, operation) do
    %__MODULE__{
      type: jsonrpc_code_to_type(code),
      message: message,
      operation: operation,
      details: data,
      server_error: %{code: code, message: message, data: data}
    }
  end

  # Invalid response structure
  def normalize(:invalid_response, operation) do
    %__MODULE__{
      type: :invalid_response,
      message: "Server returned invalid response",
      operation: operation
    }
  end

  def normalize({:invalid_response, reason}, operation) do
    %__MODULE__{
      type: :invalid_response,
      message: "Server returned invalid response: #{inspect(reason)}",
      operation: operation,
      details: %{reason: reason}
    }
  end

  # Transport errors
  def normalize({:transport_error, reason}, operation) do
    %__MODULE__{
      type: :transport_error,
      message: "Transport error: #{inspect(reason)}",
      operation: operation,
      details: %{reason: reason}
    }
  end

  # Decode errors
  def normalize({:decode_error, reason}, operation) do
    %__MODULE__{
      type: :decode_error,
      message: "JSON decode error: #{inspect(reason)}",
      operation: operation,
      details: %{reason: reason}
    }
  end

  # Capability mismatch
  def normalize({:capability_not_supported, capability}, operation) do
    %__MODULE__{
      type: :capability_not_supported,
      message: "Server does not support capability: #{inspect(capability)}",
      operation: operation,
      details: %{capability: capability}
    }
  end

  # Generic error
  def normalize(reason, operation) when is_binary(reason) do
    %__MODULE__{
      type: :unknown_error,
      message: reason,
      operation: operation
    }
  end

  def normalize(reason, operation) do
    %__MODULE__{
      type: :unknown_error,
      message: "Unknown error: #{inspect(reason)}",
      operation: operation,
      details: %{reason: reason}
    }
  end

  @doc """
  Convert JSON-RPC error code to error type.

  ## Examples

      iex> Error.jsonrpc_code_to_type(-32601)
      :method_not_found

      iex> Error.jsonrpc_code_to_type(-32001)
      :resource_not_found
  """
  @spec jsonrpc_code_to_type(integer()) :: error_type()
  def jsonrpc_code_to_type(code)

  # Standard JSON-RPC 2.0 errors
  def jsonrpc_code_to_type(-32700), do: :parse_error
  def jsonrpc_code_to_type(-32600), do: :invalid_request
  def jsonrpc_code_to_type(-32601), do: :method_not_found
  def jsonrpc_code_to_type(-32602), do: :invalid_params
  def jsonrpc_code_to_type(-32603), do: :internal_error

  # MCP-specific errors
  def jsonrpc_code_to_type(-32001), do: :resource_not_found
  def jsonrpc_code_to_type(-32002), do: :resource_not_readable
  def jsonrpc_code_to_type(-32003), do: :tool_not_found
  def jsonrpc_code_to_type(-32004), do: :tool_execution_failed
  def jsonrpc_code_to_type(-32005), do: :prompt_not_found
  def jsonrpc_code_to_type(-32006), do: :sampling_not_supported
  def jsonrpc_code_to_type(-32007), do: :capability_not_supported

  # Unknown error code
  def jsonrpc_code_to_type(_), do: :internal_error
end
```

### 2. McpClient.NotificationRouter Module

**File:** `lib/mcp_client/notification_router.ex`

**Purpose:** Route server notifications to typed tuples for pattern matching.

**Implementation:**

```elixir
defmodule McpClient.NotificationRouter do
  @moduledoc """
  Routes server-initiated notifications to typed callbacks.

  Converts raw JSON-RPC notifications into typed tuples that applications
  can pattern match against.

  ## Example

      notification_handler = fn notification ->
        case NotificationRouter.route(notification) do
          {:resources, :updated, params} ->
            Logger.info("Resource updated: \#{params["uri"]}")

          {:tools, :list_changed, _params} ->
            Logger.info("Tools changed")

          _ -> :ok
        end
      end

      {:ok, conn} = McpClient.start_link(
        transport: {...},
        notification_handler: notification_handler
      )
  """

  @type notification :: map()
  @type route ::
    {:tools, :list_changed, params :: map()}
    | {:resources, :updated, params :: map()}
    | {:resources, :list_changed, params :: map()}
    | {:prompts, :list_changed, params :: map()}
    | {:logging, :message, params :: map()}
    | {:progress, params :: map()}
    | {:cancelled, params :: map()}
    | {:roots, :list_changed, params :: map()}
    | {:unknown, notification()}

  @doc """
  Route a notification to a typed tuple.

  ## Examples

      iex> NotificationRouter.route(%{
      ...>   "method" => "notifications/resources/updated",
      ...>   "params" => %{"uri" => "file:///foo"}
      ...> })
      {:resources, :updated, %{"uri" => "file:///foo"}}

      iex> NotificationRouter.route(%{
      ...>   "method" => "notifications/tools/list_changed"
      ...> })
      {:tools, :list_changed, %{}}

      iex> NotificationRouter.route(%{
      ...>   "method" => "unknown/notification"
      ...> })
      {:unknown, %{"method" => "unknown/notification"}}
  """
  @spec route(notification()) :: route()
  def route(notification)

  # Tools notifications
  def route(%{"method" => "notifications/tools/list_changed", "params" => params})
      when is_map(params) do
    {:tools, :list_changed, params}
  end

  def route(%{"method" => "notifications/tools/list_changed"}) do
    {:tools, :list_changed, %{}}
  end

  # Resources notifications
  def route(%{"method" => "notifications/resources/updated", "params" => params})
      when is_map(params) do
    {:resources, :updated, params}
  end

  def route(%{"method" => "notifications/resources/updated"}) do
    {:resources, :updated, %{}}
  end

  def route(%{"method" => "notifications/resources/list_changed", "params" => params})
      when is_map(params) do
    {:resources, :list_changed, params}
  end

  def route(%{"method" => "notifications/resources/list_changed"}) do
    {:resources, :list_changed, %{}}
  end

  # Prompts notifications
  def route(%{"method" => "notifications/prompts/list_changed", "params" => params})
      when is_map(params) do
    {:prompts, :list_changed, params}
  end

  def route(%{"method" => "notifications/prompts/list_changed"}) do
    {:prompts, :list_changed, %{}}
  end

  # Logging notifications
  def route(%{"method" => "notifications/message", "params" => params})
      when is_map(params) do
    {:logging, :message, params}
  end

  def route(%{"method" => "notifications/message"}) do
    {:logging, :message, %{}}
  end

  # Progress notifications
  def route(%{"method" => "notifications/progress", "params" => params})
      when is_map(params) do
    {:progress, params}
  end

  def route(%{"method" => "notifications/progress"}) do
    {:progress, %{}}
  end

  # Cancellation notifications
  def route(%{"method" => "notifications/cancelled", "params" => params})
      when is_map(params) do
    {:cancelled, params}
  end

  def route(%{"method" => "notifications/cancelled"}) do
    {:cancelled, %{}}
  end

  # Roots notifications (from client)
  def route(%{"method" => "notifications/roots/list_changed", "params" => params})
      when is_map(params) do
    {:roots, :list_changed, params}
  end

  def route(%{"method" => "notifications/roots/list_changed"}) do
    {:roots, :list_changed, %{}}
  end

  # Unknown notification
  def route(notification) do
    {:unknown, notification}
  end
end
```

---

## Tests

### 3. Error Normalization Tests

**File:** `test/mcp_client/error_test.exs`

```elixir
defmodule McpClient.ErrorTest do
  use ExUnit.Case, async: true

  alias McpClient.Error

  describe "normalize/2" do
    test "normalizes timeout error" do
      error = Error.normalize(:timeout, :tools_list)

      assert %Error{
        type: :timeout,
        message: "Request timed out",
        operation: :tools_list
      } = error
    end

    test "normalizes connection closed error" do
      error = Error.normalize(:connection_closed, :resources_read)

      assert %Error{
        type: :connection_closed,
        message: "Connection closed",
        operation: :resources_read
      } = error
    end

    test "normalizes connection closed with reason" do
      error = Error.normalize({:connection_closed, :port_terminated}, :prompts_get)

      assert %Error{
        type: :connection_closed,
        message: message,
        operation: :prompts_get,
        details: %{reason: :port_terminated}
      } = error

      assert message =~ "port_terminated"
    end

    test "normalizes JSON-RPC method not found error" do
      error = Error.normalize(
        {:jsonrpc_error, -32601, "Method not found", %{"method" => "unknown"}},
        :tools_call
      )

      assert %Error{
        type: :method_not_found,
        message: "Method not found",
        operation: :tools_call,
        details: %{"method" => "unknown"},
        server_error: %{
          code: -32601,
          message: "Method not found",
          data: %{"method" => "unknown"}
        }
      } = error
    end

    test "normalizes MCP resource not found error" do
      error = Error.normalize(
        {:jsonrpc_error, -32001, "Resource not found", %{"uri" => "file:///missing"}},
        :resources_read
      )

      assert %Error{
        type: :resource_not_found,
        message: "Resource not found",
        operation: :resources_read
      } = error
    end

    test "normalizes invalid response error" do
      error = Error.normalize({:invalid_response, :missing_field}, :tools_list)

      assert %Error{
        type: :invalid_response,
        message: message,
        operation: :tools_list,
        details: %{reason: :missing_field}
      } = error

      assert message =~ "invalid response"
    end

    test "normalizes capability not supported error" do
      error = Error.normalize(
        {:capability_not_supported, [:resources, :subscribe]},
        :resources_subscribe
      )

      assert %Error{
        type: :capability_not_supported,
        message: message,
        operation: :resources_subscribe,
        details: %{capability: [:resources, :subscribe]}
      } = error

      assert message =~ "does not support capability"
    end

    test "normalizes string error" do
      error = Error.normalize("Custom error message", :tools_call)

      assert %Error{
        type: :unknown_error,
        message: "Custom error message",
        operation: :tools_call
      } = error
    end

    test "normalizes unknown error term" do
      error = Error.normalize({:unexpected, :error}, :prompts_list)

      assert %Error{
        type: :unknown_error,
        message: message,
        operation: :prompts_list,
        details: %{reason: {:unexpected, :error}}
      } = error

      assert message =~ "Unknown error"
    end
  end

  describe "jsonrpc_code_to_type/1" do
    test "maps standard JSON-RPC error codes" do
      assert Error.jsonrpc_code_to_type(-32700) == :parse_error
      assert Error.jsonrpc_code_to_type(-32600) == :invalid_request
      assert Error.jsonrpc_code_to_type(-32601) == :method_not_found
      assert Error.jsonrpc_code_to_type(-32602) == :invalid_params
      assert Error.jsonrpc_code_to_type(-32603) == :internal_error
    end

    test "maps MCP-specific error codes" do
      assert Error.jsonrpc_code_to_type(-32001) == :resource_not_found
      assert Error.jsonrpc_code_to_type(-32002) == :resource_not_readable
      assert Error.jsonrpc_code_to_type(-32003) == :tool_not_found
      assert Error.jsonrpc_code_to_type(-32004) == :tool_execution_failed
      assert Error.jsonrpc_code_to_type(-32005) == :prompt_not_found
      assert Error.jsonrpc_code_to_type(-32006) == :sampling_not_supported
      assert Error.jsonrpc_code_to_type(-32007) == :capability_not_supported
    end

    test "maps unknown codes to internal_error" do
      assert Error.jsonrpc_code_to_type(-1) == :internal_error
      assert Error.jsonrpc_code_to_type(500) == :internal_error
    end
  end
end
```

### 4. Notification Router Tests

**File:** `test/mcp_client/notification_router_test.exs`

```elixir
defmodule McpClient.NotificationRouterTest do
  use ExUnit.Case, async: true

  alias McpClient.NotificationRouter

  describe "route/1" do
    test "routes tools/list_changed notification" do
      notification = %{
        "method" => "notifications/tools/list_changed"
      }

      assert {:tools, :list_changed, %{}} = NotificationRouter.route(notification)
    end

    test "routes tools/list_changed with params" do
      notification = %{
        "method" => "notifications/tools/list_changed",
        "params" => %{"reason" => "tool added"}
      }

      assert {:tools, :list_changed, %{"reason" => "tool added"}} =
        NotificationRouter.route(notification)
    end

    test "routes resources/updated notification" do
      notification = %{
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "file:///foo.txt"}
      }

      assert {:resources, :updated, %{"uri" => "file:///foo.txt"}} =
        NotificationRouter.route(notification)
    end

    test "routes resources/list_changed notification" do
      notification = %{
        "method" => "notifications/resources/list_changed"
      }

      assert {:resources, :list_changed, %{}} = NotificationRouter.route(notification)
    end

    test "routes prompts/list_changed notification" do
      notification = %{
        "method" => "notifications/prompts/list_changed"
      }

      assert {:prompts, :list_changed, %{}} = NotificationRouter.route(notification)
    end

    test "routes logging/message notification" do
      notification = %{
        "method" => "notifications/message",
        "params" => %{
          "level" => "info",
          "logger" => "server.database",
          "data" => "Connected"
        }
      }

      assert {:logging, :message, params} = NotificationRouter.route(notification)
      assert params["level"] == "info"
      assert params["logger"] == "server.database"
      assert params["data"] == "Connected"
    end

    test "routes progress notification" do
      notification = %{
        "method" => "notifications/progress",
        "params" => %{
          "progressToken" => "op-123",
          "progress" => 0.5,
          "total" => 1.0
        }
      }

      assert {:progress, params} = NotificationRouter.route(notification)
      assert params["progressToken"] == "op-123"
      assert params["progress"] == 0.5
    end

    test "routes cancelled notification" do
      notification = %{
        "method" => "notifications/cancelled",
        "params" => %{
          "requestId" => 42,
          "reason" => "User cancelled"
        }
      }

      assert {:cancelled, params} = NotificationRouter.route(notification)
      assert params["requestId"] == 42
    end

    test "routes roots/list_changed notification" do
      notification = %{
        "method" => "notifications/roots/list_changed"
      }

      assert {:roots, :list_changed, %{}} = NotificationRouter.route(notification)
    end

    test "routes unknown notification" do
      notification = %{
        "method" => "notifications/unknown/type",
        "params" => %{"foo" => "bar"}
      }

      assert {:unknown, ^notification} = NotificationRouter.route(notification)
    end

    test "routes malformed notification" do
      notification = %{"no_method_field" => true}

      assert {:unknown, ^notification} = NotificationRouter.route(notification)
    end
  end
end
```

---

## Success Criteria

After completing this prompt, verify:

1. ✅ `mix test test/mcp_client/error_test.exs` - all tests pass
2. ✅ `mix test test/mcp_client/notification_router_test.exs` - all tests pass
3. ✅ No compilation warnings
4. ✅ `mix format --check-formatted` passes
5. ✅ `mix credo --strict` passes (if configured)

**Manual verification:**

```elixir
# Error normalization
alias McpClient.Error
error = Error.normalize(:timeout, :tools_list)
# => %Error{type: :timeout, message: "Request timed out", operation: :tools_list}

# Notification routing
alias McpClient.NotificationRouter
route = NotificationRouter.route(%{"method" => "notifications/resources/updated", "params" => %{"uri" => "file:///foo"}})
# => {:resources, :updated, %{"uri" => "file:///foo"}}
```

---

## Constraints

- ✅ **DO** use TypedStruct for Error struct
- ✅ **DO** handle all standard JSON-RPC error codes
- ✅ **DO** handle all MCP-specific error codes
- ✅ **DO** provide sensible defaults (empty map for missing params)
- ❌ **DON'T** add business logic to these modules (pure data transformation)
- ❌ **DON'T** call Connection or Transport (these are standalone utilities)
- ❌ **DON'T** add logging (caller decides whether to log)

---

## Implementation Notes

**Error normalization:**
- Always produce valid Error struct (never crash)
- Preserve original error details in `server_error` field
- Use descriptive messages for debugging

**Notification routing:**
- Return tuple `{category, subcategory, params}` for known types
- Return `{:unknown, notification}` for unrecognized notifications
- Never crash on malformed input (graceful degradation)

**Testing:**
- Test all error code mappings
- Test all notification types
- Test edge cases (missing params, unknown codes, malformed notifications)

---

## Next Steps

After completing PROMPT_10:
- **PROMPT_11**: Implement McpClient.Tools module
- **PROMPT_12**: Implement McpClient.Resources module
- **PROMPT_13**: Implement McpClient.Prompts module

---

**Estimated time:** 30 minutes
**Difficulty:** Low (pure data transformation)
**Blockers:** None (standalone modules)
