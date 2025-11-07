# PROMPT_15: Feature Integration Tests

**Goal:** Integration tests for all MCP client features with real servers.

**Duration:** ~60 minutes | **Dependencies:** PROMPT_01-14 (All features complete)

---

## Context

Integration tests verify the complete stack (Connection → Features) against real MCP servers. Unlike unit tests with mocks, these tests:
- Use actual MCP servers (stdio transport)
- Test complete request/response flows
- Verify notification handling
- Test error scenarios

---

## Implementation

**File:** `test/mcp_client/features_integration_test.exs`

```elixir
defmodule McpClient.FeaturesIntegrationTest do
  use ExUnit.Case, async: false  # Real servers, no parallelism

  alias McpClient.{Tools, Resources, Prompts}

  @moduletag :integration
  @moduletag timeout: 60_000

  # Use a real MCP server for testing
  # Example: mcp-server-sqlite, mcp-server-filesystem
  # Requires: uvx or npx installed
  @test_server_cmd "uvx"
  @test_server_args ["mcp-server-memory"]  # Simple in-memory server

  setup do
    # Start connection to test server
    {:ok, conn} = McpClient.start_link(
      transport: {
        McpClient.Transports.Stdio,
        cmd: @test_server_cmd,
        args: @test_server_args
      }
    )

    on_exit(fn -> McpClient.stop(conn) end)

    {:ok, conn: conn}
  end

  describe "Tools feature" do
    test "lists and calls tools", %{conn: conn} do
      # List tools
      assert {:ok, tools} = Tools.list(conn)
      assert is_list(tools)
      assert length(tools) > 0

      # Verify tool structure
      tool = List.first(tools)
      assert is_binary(tool.name)
      assert is_map(tool.inputSchema)

      # Call a tool
      assert {:ok, result} = Tools.call(conn, tool.name, %{})
      assert is_list(result.content)
      assert is_boolean(result.isError)
    end

    test "handles tool not found error", %{conn: conn} do
      assert {:error, error} = Tools.call(conn, "nonexistent_tool", %{})
      assert error.type in [:tool_not_found, :method_not_found]
    end
  end

  describe "Resources feature" do
    test "lists resources", %{conn: conn} do
      case Resources.list(conn) do
        {:ok, resources} ->
          assert is_list(resources)
          # Test server may have no resources
          if length(resources) > 0 do
            resource = List.first(resources)
            assert is_binary(resource.uri)
            assert is_binary(resource.name)
          end

        {:error, error} ->
          # Server may not support resources
          assert error.type == :method_not_found
      end
    end

    @tag :skip  # Only run if server supports resources
    test "reads and subscribes to resources", %{conn: conn} do
      {:ok, resources} = Resources.list(conn)
      resource = List.first(resources)

      # Read resource
      assert {:ok, contents} = Resources.read(conn, resource.uri)
      assert is_list(contents.contents)

      # Subscribe (no error = success)
      assert :ok = Resources.subscribe(conn, resource.uri)
      assert :ok = Resources.unsubscribe(conn, resource.uri)
    end
  end

  describe "Prompts feature" do
    test "lists and gets prompts", %{conn: conn} do
      case Prompts.list(conn) do
        {:ok, prompts} ->
          assert is_list(prompts)

          if length(prompts) > 0 do
            prompt = List.first(prompts)
            assert is_binary(prompt.name)

            # Get prompt
            args = build_prompt_args(prompt.arguments)
            assert {:ok, result} = Prompts.get(conn, prompt.name, args)
            assert is_list(result.messages)
          end

        {:error, error} ->
          # Server may not support prompts
          assert error.type == :method_not_found
      end
    end
  end

  describe "Notification handling" do
    test "receives notifications", %{conn: conn} do
      # Register notification handler
      handler = fn notification ->
        send(self(), {:notification_received, notification})
        :ok
      end

      # Note: Would need to reconfigure connection with handler
      # or trigger notifications from server
      # This test is placeholder for real notification testing
    end
  end

  describe "Error handling" do
    test "handles connection timeout", %{conn: conn} do
      # Call with very short timeout on slow operation
      assert {:error, error} = Tools.list(conn, timeout: 1)
      assert error.type == :timeout
    end

    test "handles invalid method", %{conn: conn} do
      # Direct Connection.call with invalid method
      assert {:error, error} = McpClient.Connection.call(
        conn,
        "invalid/method",
        %{},
        5000
      )
      # Will be normalized by Error module
    end
  end

  # Helper: Build arguments for prompt
  defp build_prompt_args(nil), do: %{}
  defp build_prompt_args([]), do: %{}
  defp build_prompt_args(args) do
    args
    |> Enum.filter(& &1.required)
    |> Enum.map(fn arg -> {arg.name, "test_value"} end)
    |> Map.new()
  end
end
```

---

## Running Integration Tests

**Prerequisites:**
```bash
# Install test MCP server
uvx mcp-server-memory
# or
npx -y @modelcontextprotocol/server-memory
```

**Run tests:**
```bash
# All tests including integration
mix test --include integration

# Only integration tests
mix test --only integration

# Specific test file
mix test test/mcp_client/features_integration_test.exs
```

**CI Configuration:**

Skip integration tests in CI unless MCP servers are available:

```yaml
# .github/workflows/test.yml
- name: Run tests
  run: mix test --exclude integration
```

---

## Success Criteria

1. ✅ All integration tests pass with real MCP server
2. ✅ Tests cover Tools, Resources, Prompts features
3. ✅ Error handling verified (timeout, not found, etc.)
4. ✅ Tests run in CI (or skipped with @moduletag)

---

## Constraints

- ✅ **DO** use real MCP servers (stdio transport)
- ✅ **DO** test happy paths and common errors
- ✅ **DO** skip tests if server not available
- ❌ **DON'T** mock Connection (use real implementation)
- ❌ **DON'T** test internal state (black-box testing)

---

## Testing Strategy

**Unit tests** (PROMPT_10-14):
- Test individual modules with mocks
- Fast, isolated, parallelizable

**Integration tests** (PROMPT_15):
- Test full stack with real servers
- Slower, sequential, require setup

**Coverage target:** >90% for feature modules

---

**Completion:** All implementation prompts (01-15) complete!
**Next:** Update implementation/README.md with new prompts, create usage guides
