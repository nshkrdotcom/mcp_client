# PROMPT_11: Tools Feature Module

**Goal:** Implement `MCPClient.Tools` module for listing and calling MCP tools.

**Duration:** ~45 minutes

**Dependencies:** PROMPT_01-10 (Core + Infrastructure)

---

## Context

Tools allow servers to expose executable functions. This module provides:
- `list/2` - List available tools from server
- `call/4` - Execute a tool with arguments

All errors are normalized through `MCPClient.Error`, and all operations use the core `Connection.call/4` function.

---

## Required Reading

**ADR-0011:** Client Features Architecture - Section: "MCPClient.Tools"
**CLIENT_FEATURES.md:** Section: "MCPClient.Tools" - Complete API specification
**PROTOCOL_DETAILS.md:** Sections: "tools/list" and "tools/call" message schemas

---

## Implementation

**File:** `lib/mcp_client/tools.ex`

```elixir
defmodule MCPClient.Tools do
  @moduledoc """
  Client API for MCP Tools feature.

  Tools allow servers to expose executable functions that can be called
  by the client with validated arguments.

  ## Example

      {:ok, tools} = MCPClient.Tools.list(conn)
      # => [%Tool{name: "search", description: "Search files", ...}]

      {:ok, result} = MCPClient.Tools.call(conn, "search", %{query: "TODO"})
      # => %CallResult{content: [...], isError: false}
  """

  use TypedStruct

  alias MCPClient.{Connection, Error}

  typedstruct module: Tool do
    @moduledoc "A tool exposed by the server"
    field :name, String.t(), enforce: true
    field :description, String.t()
    field :inputSchema, map(), enforce: true
  end

  typedstruct module: CallResult do
    @moduledoc "Result from calling a tool"
    field :content, [map()], default: []
    field :isError, boolean(), default: false
  end

  @type list_opts :: [timeout: timeout()]
  @type call_opts :: [timeout: timeout()]

  @doc """
  List available tools from the server.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 30_000)

  ## Examples

      {:ok, tools} = MCPClient.Tools.list(conn)
      {:ok, tools} = MCPClient.Tools.list(conn, timeout: 10_000)
  """
  @spec list(pid(), list_opts()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def list(conn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, result} <- Connection.call(conn, "tools/list", %{}, timeout),
         {:ok, tools} <- validate_list_response(result) do
      {:ok, tools}
    else
      {:error, reason} -> {:error, Error.normalize(reason, :tools_list)}
    end
  end

  @doc """
  Call a tool with arguments.

  ## Options

  - `:timeout` - Request timeout in milliseconds (default: 30_000)

  ## Examples

      {:ok, result} = MCPClient.Tools.call(conn, "search", %{query: "TODO"})

      {:ok, result} = MCPClient.Tools.call(conn, "read_file", %{path: "/foo.txt"}, timeout: 60_000)
  """
  @spec call(pid(), String.t(), map(), call_opts()) ::
    {:ok, CallResult.t()} | {:error, Error.t()}
  def call(conn, name, arguments, opts \\ []) when is_binary(name) and is_map(arguments) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    params = %{name: name, arguments: arguments}

    with {:ok, result} <- Connection.call(conn, "tools/call", params, timeout),
         {:ok, call_result} <- validate_call_response(result) do
      {:ok, call_result}
    else
      {:error, reason} -> {:error, Error.normalize(reason, :tools_call)}
    end
  end

  # Private: Validate tools/list response
  defp validate_list_response(%{"tools" => tools}) when is_list(tools) do
    case validate_all_tools(tools) do
      {:ok, validated} -> {:ok, validated}
      {:error, _} = err -> err
    end
  end
  defp validate_list_response(_), do: {:error, {:invalid_response, :missing_tools_field}}

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

  defp validate_tool(%{"name" => name, "inputSchema" => schema} = tool)
      when is_binary(name) and is_map(schema) do
    {:ok, %Tool{
      name: name,
      description: Map.get(tool, "description"),
      inputSchema: schema
    }}
  end
  defp validate_tool(_), do: {:error, {:invalid_response, :invalid_tool_structure}}

  # Private: Validate tools/call response
  defp validate_call_response(%{"content" => content} = result) when is_list(content) do
    {:ok, %CallResult{
      content: content,
      isError: Map.get(result, "isError", false)
    }}
  end
  defp validate_call_response(_), do: {:error, {:invalid_response, :missing_content_field}}
end
```

---

## Tests

**File:** `test/mcp_client/tools_test.exs`

```elixir
defmodule MCPClient.ToolsTest do
  use ExUnit.Case, async: true

  alias MCPClient.{Tools, Error}
  alias Tools.{Tool, CallResult}

  # Mock connection for testing
  defmodule MockConnection do
    def call(_conn, method, params, _timeout) do
      send(self(), {:call, method, params})
      receive do
        {:response, response} -> response
      after
        100 -> {:error, :timeout}
      end
    end
  end

  setup do
    # Inject mock connection
    Application.put_env(:mcp_client, :connection_module, MockConnection)
    on_exit(fn -> Application.delete_env(:mcp_client, :connection_module) end)
    :ok
  end

  describe "list/2" do
    test "lists tools successfully" do
      Task.async(fn ->
        assert_receive {:call, "tools/list", %{}}
        send(self(), {:response, {:ok, %{
          "tools" => [
            %{
              "name" => "search",
              "description" => "Search files",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }}})
      end)

      assert {:ok, [tool]} = Tools.list(:mock_conn)
      assert %Tool{name: "search", description: "Search files"} = tool
    end

    test "handles empty tool list" do
      Task.async(fn ->
        assert_receive {:call, "tools/list", %{}}
        send(self(), {:response, {:ok, %{"tools" => []}}})
      end)

      assert {:ok, []} = Tools.list(:mock_conn)
    end

    test "normalizes timeout error" do
      # Don't send response, let it timeout
      assert {:error, %Error{type: :timeout, operation: :tools_list}} = Tools.list(:mock_conn)
    end

    test "normalizes server error" do
      Task.async(fn ->
        assert_receive {:call, "tools/list", %{}}
        send(self(), {:response, {:error, {:jsonrpc_error, -32601, "Not found", %{}}}})
      end)

      assert {:error, %Error{type: :method_not_found, operation: :tools_list}} =
        Tools.list(:mock_conn)
    end

    test "rejects invalid response structure" do
      Task.async(fn ->
        assert_receive {:call, "tools/list", %{}}
        send(self(), {:response, {:ok, %{"invalid" => "response"}}})
      end)

      assert {:error, %Error{type: :invalid_response, operation: :tools_list}} =
        Tools.list(:mock_conn)
    end
  end

  describe "call/4" do
    test "calls tool successfully" do
      Task.async(fn ->
        assert_receive {:call, "tools/call", %{name: "search", arguments: %{query: "TODO"}}}
        send(self(), {:response, {:ok, %{
          "content" => [%{"type" => "text", "text" => "Found 3 TODOs"}],
          "isError" => false
        }}})
      end)

      assert {:ok, result} = Tools.call(:mock_conn, "search", %{query: "TODO"})
      assert %CallResult{content: [%{"type" => "text"}], isError: false} = result
    end

    test "handles tool error result" do
      Task.async(fn ->
        assert_receive {:call, "tools/call", _}
        send(self(), {:response, {:ok, %{
          "content" => [%{"type" => "text", "text" => "Error: File not found"}],
          "isError" => true
        }}})
      end)

      assert {:ok, result} = Tools.call(:mock_conn, "read_file", %{path: "/missing"})
      assert result.isError == true
    end

    test "validates tool name is string" do
      assert_raise FunctionClauseError, fn ->
        Tools.call(:mock_conn, :not_a_string, %{})
      end
    end

    test "validates arguments is map" do
      assert_raise FunctionClauseError, fn ->
        Tools.call(:mock_conn, "tool", "not a map")
      end
    end
  end
end
```

---

## Success Criteria

1. ✅ `mix test test/mcp_client/tools_test.exs` - all tests pass
2. ✅ No compilation warnings
3. ✅ `mix format --check-formatted` passes
4. ✅ `mix credo` passes

**Manual verification** (with real server):
```elixir
{:ok, conn} = MCPClient.start_link(transport: {Stdio, cmd: "mcp-server"})
{:ok, tools} = MCPClient.Tools.list(conn)
{:ok, result} = MCPClient.Tools.call(conn, List.first(tools).name, %{})
```

---

## Constraints

- ✅ **DO** use Connection.call/4 for all requests
- ✅ **DO** normalize all errors through Error.normalize/2
- ✅ **DO** validate response structure
- ❌ **DON'T** add caching (application concern)
- ❌ **DON'T** add retry logic (handled by Connection)
- ❌ **DON'T** call Transport directly

---

**Next:** PROMPT_12 - Resources feature module
