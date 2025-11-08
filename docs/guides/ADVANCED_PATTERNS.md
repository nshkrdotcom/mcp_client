# Advanced Patterns

Production-ready patterns for building robust MCP Client applications.

---

## Overview

This guide covers advanced patterns for:
- Usage patterns (direct vs code execution)
- Connection management and pooling
- Caching strategies
- Performance optimization
- Testing strategies
- Monitoring and observability
- Security best practices

---

## Usage Patterns: Direct vs Code Execution

MCP Client supports two fundamentally different usage patterns. Choosing the right pattern is critical for agent performance at scale.

### Pattern A: Direct Tool Calls

**Best for:** < 50 tools, simple workflows, prototyping

**How it works:** Load all tool definitions upfront, call tools directly through the model.

```elixir
# Connect to MCP server
{:ok, conn} = McpClient.start_link(
  transport: {McpClient.Transports.Stdio, cmd: "mcp-server"}
)

# Load all tools (into context)
{:ok, tools} = McpClient.Tools.list(conn)
# => 100 tools × 150 tokens/tool = 15K tokens

# Call tools directly (results through context)
{:ok, result} = McpClient.Tools.call(conn, "search", %{query: "test"})
# => Result flows through model context
```

**Pros:**
- ✅ Simple to implement
- ✅ No additional infrastructure
- ✅ Works out of the box

**Cons:**
- ❌ All tools loaded upfront (10K-150K tokens)
- ❌ All results flow through context
- ❌ High latency with many tools
- ❌ High token cost

**Token usage example:** ~250K tokens for workflow with 1000 tools

### Pattern B: Code Execution

**Best for:** 100+ tools, complex workflows, production agents

**How it works:** Generate code APIs from tools, agent writes code to interact with servers.

```elixir
# Generate modules from MCP servers (one-time)
mix mcp.gen.server google_drive --output lib/mcp_servers/
mix mcp.gen.server salesforce --output lib/mcp_servers/

# Agent discovers tools progressively (filesystem/search)
servers = File.ls!("lib/mcp_servers")
# => ["google_drive", "salesforce"]

# Agent writes code (executes in sandbox)
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

# Data flows through execution environment, not model context
{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
transcript = doc.content  # Full data in memory, NOT in context

# Agent only sees confirmation
{:ok, _} = Salesforce.update_record(conn, "Lead", "00Q...", %{Notes: transcript})
IO.puts("Updated successfully")  # Model sees: "Updated successfully" (3 tokens)
```

**Pros:**
- ✅ Progressive tool discovery (1K-5K tokens)
- ✅ Data filtered before reaching model
- ✅ 98%+ token reduction
- ✅ Lower latency (single execution vs multiple round-trips)
- ✅ Complex control flow (loops, conditionals)

**Cons:**
- ❌ Requires code generation step
- ❌ Needs secure execution sandbox
- ❌ More complex infrastructure

**Token usage example:** ~2K tokens for same workflow (98.7% reduction!)

### Decision Matrix

| Criteria | Direct Tool Calls | Code Execution |
|----------|------------------|----------------|
| **Number of tools** | < 50 | 100+ |
| **Workflow complexity** | Simple (1-5 steps) | Complex (10+ steps) |
| **Data volume** | Small results | Large datasets |
| **Token budget** | Unlimited | Cost-sensitive |
| **Infrastructure** | Minimal | Requires sandbox |
| **Development time** | Hours | Days (one-time setup) |
| **Performance** | Good enough | Critical |

### Real-World Impact

**Anthropic case study** (Nov 2025):
- **Before (direct):** 150K tokens → $0.30/request
- **After (code):** 2K tokens → $0.004/request
- **Savings:** 98.7% reduction, 75× cheaper

### Implementation: Code Generation (Post-MVP)

Generate Elixir modules from MCP tool definitions:

```bash
# Generate modules for a server
mix mcp.gen.server google_drive --output lib/mcp_servers/

# Generates:
# lib/mcp_servers/google_drive.ex           (main module)
# lib/mcp_servers/google_drive/get_document.ex
# lib/mcp_servers/google_drive/list_files.ex
# ... (one file per tool)
```

Each tool becomes a function:

```elixir
# lib/mcp_servers/google_drive/get_document.ex
defmodule MCPServers.GoogleDrive.GetDocument do
  @moduledoc """
  Retrieves a document from Google Drive.

  ## Parameters
  - `document_id` (required, string): The ID of the document to retrieve

  ## Returns
  Document object with title, body content, metadata
  """

  def call(conn, document_id) do
    McpClient.Connection.call(
      conn,
      "google_drive__get_document",
      %{documentId: document_id}
    )
  end
end

# Main module aggregates all tools
defmodule MCPServers.GoogleDrive do
  alias MCPServers.GoogleDrive

  defdelegate get_document(conn, document_id), to: GoogleDrive.GetDocument, as: :call
  defdelegate list_files(conn, opts \\ %{}), to: GoogleDrive.ListFiles, as: :call
  # ... other tools
end
```

### Progressive Tool Discovery

Instead of loading all tools, agent discovers progressively:

**Approach 1: Filesystem navigation**

```elixir
# Agent explores generated modules
servers = File.ls!("lib/mcp_servers")
# => ["google_drive", "salesforce", "slack"]

# List tools for specific server
tools = File.ls!("lib/mcp_servers/google_drive")
# => ["get_document.ex", "list_files.ex", "search.ex"]

# Read specific tool (only when needed)
doc = File.read!("lib/mcp_servers/google_drive/get_document.ex")
# Agent sees tool definition (200 tokens vs 15K for all tools)
```

**Approach 2: Search API (post-MVP)**

```elixir
# Search for relevant tools
{:ok, tools} = McpClient.Tools.search(conn, "salesforce update", detail: :name_only)
# => ["salesforce__update_record", "salesforce__update_lead"]  (100 tokens)

{:ok, tools} = McpClient.Tools.search(conn, "salesforce update", detail: :full)
# => [%Tool{name: "...", inputSchema: {...}}]  (2K tokens)

# Detail levels:
# - :name_only -> Just names (100 tokens)
# - :summary -> Names + descriptions (500 tokens)
# - :full -> Complete schemas (2K tokens)
```

### Benefits of Code Execution

#### 1. Context-Efficient Data Processing

Filter large datasets before they reach the model:

```elixir
# Without code execution - all 10K rows in context
{:ok, sheet} = McpClient.Resources.read(conn, "sheet://abc123")
# => 10K rows × 50 tokens = 500K tokens in context

# With code execution - filter before context
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "abc123")
pending = Enum.filter(sheet.rows, & &1["Status"] == "pending")

IO.puts("Found #{length(pending)} pending orders")
IO.inspect(Enum.take(pending, 5))
# => Model sees 5 rows + summary = 250 tokens (99.95% reduction!)
```

#### 2. Complex Control Flow

Loops and conditionals without model round-trips:

```elixir
# Poll for deployment notification
found = false
while !found do
  {:ok, messages} = MCPServers.Slack.get_channel_history(conn, "C123456")
  found = Enum.any?(messages, & String.contains?(&1.text, "deployment complete"))

  unless found do
    Process.sleep(5000)
  end
end

IO.puts("Deployment complete")
# Single execution, no model involvement during polling
```

#### 3. Privacy-Preserving Operations

Sensitive data flows through workflow without entering model context:

```elixir
# Sync customer data: Sheets → Salesforce (without model seeing PII)
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "customers")

Enum.each(sheet.rows, fn row ->
  MCPServers.Salesforce.update_record(conn, "Lead", row.id, %{
    Email: row.email,      # PII never enters model context
    Phone: row.phone,
    Name: row.name
  })
end)

IO.puts("Synced #{length(sheet.rows)} customers")
# Model sees: "Synced 1000 customers" (no PII)
```

With tokenization layer (post-MVP), even logged data is safe:

```elixir
# Agent writes normal code
IO.inspect(sheet.rows)
# But sees: [%{email: "[EMAIL_1]", phone: "[PHONE_1]", ...}]

# MCP Client untokenizes when sending to servers
MCPServers.Salesforce.update_record(...)  # Real data sent
```

#### 4. Reusable Skills

Agents can save working code as reusable functions:

```elixir
# Agent develops solution
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "abc123")
csv = Enum.map_join(sheet.rows, "\n", fn row ->
  Enum.map_join(row, ",", & &1)
end)
File.write!("output.csv", csv)

# Save as skill
defmodule Skills.ExportSheetToCsv do
  def run(conn, sheet_id, output_path) do
    {:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, sheet_id)
    csv = Enum.map_join(sheet.rows, "\n", fn row ->
      Enum.map_join(row, ",", & &1)
    end)
    File.write!(output_path, csv)
    {:ok, output_path}
  end
end

# Later, any agent can use this skill
Skills.ExportSheetToCsv.run(conn, "xyz789", "report.csv")
```

### Migration Path

**Start with direct tool calls:**
```elixir
# MVP: Simple and works
{:ok, tools} = McpClient.Tools.list(conn)
{:ok, result} = McpClient.Tools.call(conn, "search", %{query: "test"})
```

**Migrate to code execution when:**
- Connecting to 100+ tools
- Context window fills up
- Token costs become significant
- Need complex control flow

**Migration is non-breaking:**
```elixir
# Old code still works
{:ok, result} = McpClient.Tools.call(conn, "search", %{query: "test"})

# New code uses generated modules
{:ok, result} = MCPServers.GoogleDrive.search(conn, "test")

# Both use same MCP Client foundation
```

### Further Reading

See [CODE_EXECUTION_PATTERN.md](../design/CODE_EXECUTION_PATTERN.md) for complete architectural details.

---

## Connection Management

### Supervised Connections

**Pattern:** Add MCP connections to application supervision tree for automatic restart.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your application services
      MyApp.Repo,
      MyAppWeb.Endpoint,

      # MCP connection
      {McpClient, mcp_config()}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp mcp_config do
    [
      name: MyApp.MCPConnection,
      transport: {
        McpClient.Transports.Stdio,
        cmd: Application.get_env(:my_app, :mcp_cmd),
        args: Application.get_env(:my_app, :mcp_args)
      },
      notification_handler: &MyApp.MCP.NotificationHandler.handle/1
    ]
  end
end
```

**Benefits:**
- Automatic restart on crash
- Clean shutdown on application stop
- Single source of truth for configuration

### Multiple Connections

**Pattern:** Manage connections to multiple MCP servers.

```elixir
defmodule MyApp.MCP.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    children = [
      # SQLite database
      {McpClient, [
        name: MyApp.MCP.Database,
        transport: {McpClient.Transports.Stdio,
                    cmd: "uvx",
                    args: ["mcp-server-sqlite", "--db-path", "./data.db"]}
      ]},

      # Filesystem
      {McpClient, [
        name: MyApp.MCP.Filesystem,
        transport: {McpClient.Transports.Stdio,
                    cmd: "uvx",
                    args: ["mcp-server-filesystem", "./files"]}
      ]},

      # Cloud API
      {McpClient, [
        name: MyApp.MCP.Cloud,
        transport: {McpClient.Transports.HTTP,
                    base_url: Application.get_env(:my_app, :mcp_cloud_url),
                    oauth: Application.get_env(:my_app, :mcp_oauth)}
      ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Helper to get connections
  def database, do: Process.whereis(MyApp.MCP.Database)
  def filesystem, do: Process.whereis(MyApp.MCP.Filesystem)
  def cloud, do: Process.whereis(MyApp.MCP.Cloud)
end

# Usage:
{:ok, tools} = McpClient.Tools.list(MyApp.MCP.Supervisor.database())
{:ok, resources} = McpClient.Resources.list(MyApp.MCP.Supervisor.filesystem())
```

### Dynamic Connection Pool

**Pattern:** Create/destroy connections dynamically based on demand.

```elixir
defmodule MyApp.MCP.ConnectionPool do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_connection(server_config) do
    spec = {McpClient, server_config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_connection(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def list_connections do
    DynamicSupervisor.which_children(__MODULE__)
  end
end

# Usage:
{:ok, conn} = MyApp.MCP.ConnectionPool.start_connection([
  transport: {McpClient.Transports.Stdio, cmd: "mcp-server"}
])

# Use connection
{:ok, tools} = McpClient.Tools.list(conn)

# Clean up when done
:ok = MyApp.MCP.ConnectionPool.stop_connection(conn)
```

### Connection Registry

**Pattern:** Register connections for lookup by key. Per ADR-0012 this is no longer optional—multi-connection deployments **must** register each connection (atom or `:via`) so transports and notification routers can locate the proper process.

```elixir
defmodule MyApp.MCP.Registry do
  def child_spec(_) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def start_connection(key, config) do
    config = Keyword.put(config, :name, via_tuple(key))
    McpClient.start_link(config)
  end

  def whereis(key) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def via_tuple(key) do
    {:via, Registry, {__MODULE__, key}}
  end
end

# Usage:
{:ok, _} = MyApp.MCP.Registry.start_connection(
  {:user, user_id},
  [transport: {...}]
)

# Lookup later
{:ok, conn} = MyApp.MCP.Registry.whereis({:user, user_id})
McpClient.Tools.list(conn)
```

---

## Caching Strategies

### Tool Result Caching

**Pattern:** Cache tool results to reduce server load.

```elixir
defmodule MyApp.MCP.ToolCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def call_cached(conn, tool_name, args, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, 60_000)  # 60 seconds default
    key = {tool_name, args}

    case get_cached(key, ttl) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        case McpClient.Tools.call(conn, tool_name, args) do
          {:ok, result} = success ->
            cache_result(key, result)
            success

          error ->
            error
        end
    end
  end

  defp get_cached(key, ttl) do
    GenServer.call(__MODULE__, {:get, key, ttl})
  end

  defp cache_result(key, result) do
    GenServer.cast(__MODULE__, {:put, key, result})
  end

  # GenServer callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_call({:get, key, ttl}, _from, state) do
    case Map.get(state, key) do
      {result, timestamp} ->
        if System.monotonic_time(:millisecond) - timestamp < ttl do
          {:reply, {:ok, result}, state}
        else
          {:reply, :miss, Map.delete(state, key)}
        end

      nil ->
        {:reply, :miss, state}
    end
  end

  def handle_cast({:put, key, result}, state) do
    timestamp = System.monotonic_time(:millisecond)
    {:noreply, Map.put(state, key, {result, timestamp})}
  end
end

# Usage:
{:ok, result} = MyApp.MCP.ToolCache.call_cached(
  conn,
  "expensive_search",
  %{query: "test"},
  ttl: 300_000  # 5 minutes
)
```

### Resource Caching with Invalidation

**Pattern:** Cache resources and invalidate on update notifications.

```elixir
defmodule MyApp.MCP.ResourceCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{cache: %{}, subscriptions: MapSet.new()}, name: __MODULE__)
  end

  def read_cached(conn, uri) do
    case GenServer.call(__MODULE__, {:get, uri}) do
      {:ok, contents} ->
        {:ok, contents}

      :miss ->
        with {:ok, contents} <- McpClient.Resources.read(conn, uri),
             :ok <- McpClient.Resources.subscribe(conn, uri) do
          GenServer.cast(__MODULE__, {:put, uri, contents})
          GenServer.cast(__MODULE__, {:subscribe, uri})
          {:ok, contents}
        end
    end
  end

  def invalidate(uri) do
    GenServer.cast(__MODULE__, {:invalidate, uri})
  end

  # GenServer callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_call({:get, uri}, _from, state) do
    case Map.get(state.cache, uri) do
      nil -> {:reply, :miss, state}
      contents -> {:reply, {:ok, contents}, state}
    end
  end

  def handle_cast({:put, uri, contents}, state) do
    {:noreply, %{state | cache: Map.put(state.cache, uri, contents)}}
  end

  def handle_cast({:invalidate, uri}, state) do
    {:noreply, %{state | cache: Map.delete(state.cache, uri)}}
  end

  def handle_cast({:subscribe, uri}, state) do
    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, uri)}}
  end
end

# Notification handler integration:
def handle_notification(notification) do
  case McpClient.NotificationRouter.route(notification) do
    {:resources, :updated, %{"uri" => uri}} ->
      MyApp.MCP.ResourceCache.invalidate(uri)

    _ -> :ok
  end

  :ok
end
```

### Capability Caching

**Pattern:** Cache server capabilities to avoid repeated queries.

```elixir
defmodule MyApp.MCP.CapabilityCache do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get_capabilities(conn) do
    case Agent.get(__MODULE__, &Map.get(&1, conn)) do
      nil ->
        caps = McpClient.server_capabilities(conn)
        Agent.update(__MODULE__, &Map.put(&1, conn, caps))
        caps

      caps ->
        caps
    end
  end

  def supports?(conn, capability_path) do
    caps = get_capabilities(conn)
    get_in(caps, capability_path) != nil
  end
end

# Usage:
if MyApp.MCP.CapabilityCache.supports?(conn, ["resources", "subscribe"]) do
  McpClient.Resources.subscribe(conn, uri)
end
```

---

## Performance Optimization

### Parallel Requests

**Pattern:** Execute multiple requests concurrently.

```elixir
defmodule MyApp.MCP.Parallel do
  def call_many(conn, requests) do
    requests
    |> Enum.map(fn {tool, args} ->
      Task.async(fn ->
        McpClient.Tools.call(conn, tool, args)
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  def read_many(conn, uris) do
    uris
    |> Enum.map(fn uri ->
      Task.async(fn ->
        McpClient.Resources.read(conn, uri)
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
  end
end

# Usage:
requests = [
  {"search", %{query: "test"}},
  {"analyze", %{data: "..."}},
  {"process", %{input: "..."}}
]

results = MyApp.MCP.Parallel.call_many(conn, requests)
```

### Request Batching

**Pattern:** Batch multiple operations into fewer server round-trips.

```elixir
defmodule MyApp.MCP.Batcher do
  use GenServer

  defstruct [:conn, :batch, :timer, :opts]

  def start_link(conn, opts \\ []) do
    GenServer.start_link(__MODULE__, {conn, opts}, name: __MODULE__)
  end

  def call_tool(tool, args) do
    GenServer.call(__MODULE__, {:add, tool, args}, 30_000)
  end

  # GenServer callbacks
  def init({conn, opts}) do
    batch_size = Keyword.get(opts, :batch_size, 10)
    batch_timeout = Keyword.get(opts, :batch_timeout, 100)

    {:ok, %__MODULE__{
      conn: conn,
      batch: [],
      timer: nil,
      opts: [batch_size: batch_size, batch_timeout: batch_timeout]
    }}
  end

  def handle_call({:add, tool, args}, from, state) do
    batch = [{tool, args, from} | state.batch]

    if length(batch) >= state.opts[:batch_size] do
      # Batch full, flush immediately
      flush_batch(batch, state.conn)
      {:noreply, %{state | batch: [], timer: cancel_timer(state.timer)}}
    else
      # Start/reset timer
      timer = schedule_flush(state.timer, state.opts[:batch_timeout])
      {:noreply, %{state | batch: batch, timer: timer}}
    end
  end

  def handle_info(:flush, state) do
    flush_batch(state.batch, state.conn)
    {:noreply, %{state | batch: [], timer: nil}}
  end

  defp flush_batch(batch, conn) do
    # Execute all requests in parallel
    batch
    |> Enum.map(fn {tool, args, from} ->
      Task.async(fn ->
        result = McpClient.Tools.call(conn, tool, args)
        {from, result}
      end)
    end)
    |> Enum.each(fn task ->
      {from, result} = Task.await(task, 30_000)
      GenServer.reply(from, result)
    end)
  end

  defp schedule_flush(nil, timeout) do
    Process.send_after(self(), :flush, timeout)
  end
  defp schedule_flush(timer, timeout) do
    Process.cancel_timer(timer)
    Process.send_after(self(), :flush, timeout)
  end

  defp cancel_timer(nil), do: nil
  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end
end

# Usage:
{:ok, result} = MyApp.MCP.Batcher.call_tool("search", %{query: "test"})
# Batches with other requests within 100ms window
```

### Streaming Results

**Pattern:** Process large result sets incrementally (application-level, not protocol).

```elixir
defmodule MyApp.MCP.Streaming do
  def stream_results(conn, tool, args) do
    Stream.resource(
      fn -> fetch_page(conn, tool, args, 0) end,
      fn
        :halt -> {:halt, nil}
        {items, page} -> {items, fetch_page(conn, tool, args, page + 1)}
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(conn, tool, args, page) do
    args_with_page = Map.merge(args, %{page: page, page_size: 100})

    case McpClient.Tools.call(conn, tool, args_with_page) do
      {:ok, %{content: content}} ->
        if Enum.empty?(content) do
          :halt
        else
          {content, page}
        end

      {:error, _} ->
        :halt
    end
  end
end

# Usage:
MyApp.MCP.Streaming.stream_results(conn, "search_all", %{query: "test"})
|> Stream.take(1000)
|> Enum.to_list()
```

---

## Testing Strategies

### Mock Connection

**Pattern:** Create mock connection for testing without real server.

```elixir
defmodule MyApp.MockConnection do
  def call(_conn, "tools/list", _params, _timeout) do
    {:ok, %{
      "tools" => [
        %{
          "name" => "mock_tool",
          "description" => "A mock tool",
          "inputSchema" => %{"type" => "object"}
        }
      ]
    }}
  end

  def call(_conn, "tools/call", %{name: "mock_tool"}, _timeout) do
    {:ok, %{
      "content" => [%{"type" => "text", "text" => "Mock result"}],
      "isError" => false
    }}
  end

  def call(_conn, _method, _params, _timeout) do
    {:error, {:jsonrpc_error, -32601, "Method not found", %{}}}
  end
end

# In tests:
test "processes tool results" do
  # Inject mock
  Application.put_env(:my_app, :mcp_connection_module, MyApp.MockConnection)

  result = MyApp.process_tool_result(:mock_conn, "mock_tool", %{})
  assert result == "processed: Mock result"
end
```

### Test Helpers

**Pattern:** Shared helpers for testing MCP functionality.

```elixir
defmodule MyApp.MCPTestHelpers do
  def start_test_server(opts \\ []) do
    cmd = Keyword.get(opts, :cmd, "mcp-test-server")
    args = Keyword.get(opts, :args, [])

    {:ok, conn} = McpClient.start_link(
      transport: {McpClient.Transports.Stdio, cmd: cmd, args: args},
      request_timeout: 5_000
    )

    on_exit(fn -> McpClient.stop(conn) end)

    conn
  end

  def assert_tool_exists(conn, tool_name) do
    {:ok, tools} = McpClient.Tools.list(conn)
    tool_names = Enum.map(tools, & &1.name)

    assert tool_name in tool_names,
           "Expected tool '#{tool_name}' to exist. Available: #{inspect(tool_names)}"
  end

  def assert_capability(conn, capability_path) do
    caps = McpClient.server_capabilities(conn)
    assert get_in(caps, capability_path) != nil,
           "Expected capability #{inspect(capability_path)} to be supported"
  end
end

# In tests:
use MyApp.MCPTestHelpers

test "calls search tool" do
  conn = start_test_server(cmd: "mcp-server-search")
  assert_tool_exists(conn, "search")

  {:ok, result} = McpClient.Tools.call(conn, "search", %{query: "test"})
  assert result.isError == false
end
```

### Integration Test Pattern

**Pattern:** Comprehensive integration tests with real servers.

```elixir
defmodule MyApp.MCPIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  setup_all do
    # Start real server
    {:ok, conn} = McpClient.start_link(
      transport: {McpClient.Transports.Stdio,
                  cmd: "uvx",
                  args: ["mcp-server-memory"]}
    )

    on_exit(fn -> McpClient.stop(conn) end)

    %{conn: conn}
  end

  test "full workflow: list tools, call tool, check result", %{conn: conn} do
    # List tools
    assert {:ok, tools} = McpClient.Tools.list(conn)
    assert length(tools) > 0

    # Find a tool
    tool = List.first(tools)
    assert is_binary(tool.name)

    # Call tool
    assert {:ok, result} = McpClient.Tools.call(conn, tool.name, %{})
    assert is_list(result.content)
  end

  test "handles notifications", %{conn: conn} do
    # This would require a server that sends notifications
    # Set up notification handler, trigger notification, verify received
  end
end
```

---

## Monitoring & Observability

### Telemetry Integration

**Pattern:** Emit telemetry events for monitoring.

```elixir
defmodule MyApp.MCP.Telemetry do
  def attach do
    events = [
      [:mcp_client, :request, :start],
      [:mcp_client, :request, :stop],
      [:mcp_client, :request, :exception],
      [:mcp_client, :connection, :state_change]
    ]

    :telemetry.attach_many(
      "myapp-mcp-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  def handle_event([:mcp_client, :request, :start], measurements, metadata, _config) do
    # Log request start
    Logger.debug("MCP request started: #{metadata.method}")
  end

  def handle_event([:mcp_client, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    # Log duration
    Logger.info("MCP request completed: #{metadata.method} (#{duration_ms}ms)")

    # Send to metrics backend
    :telemetry.execute(
      [:myapp, :mcp, :request],
      %{duration: duration_ms},
      %{method: metadata.method, status: :success}
    )
  end

  def handle_event([:mcp_client, :request, :exception], measurements, metadata, _config) do
    # Log error
    Logger.error("MCP request failed: #{metadata.method} - #{inspect(metadata.reason)}")

    # Send to metrics backend
    :telemetry.execute(
      [:myapp, :mcp, :request],
      %{count: 1},
      %{method: metadata.method, status: :error, type: metadata.error_type}
    )
  end

  def handle_event([:mcp_client, :connection, :state_change], _, metadata, _config) do
    Logger.info("MCP connection state: #{metadata.old_state} → #{metadata.new_state}")
  end
end
```

### Health Monitoring

**Pattern:** Periodic health checks with alerting.

```elixir
defmodule MyApp.MCP.HealthMonitor do
  use GenServer

  def start_link(conn) do
    GenServer.start_link(__MODULE__, conn, name: __MODULE__)
  end

  def init(conn) do
    schedule_check()
    {:ok, %{conn: conn, consecutive_failures: 0}}
  end

  def handle_info(:check, state) do
    case check_health(state.conn) do
      :ok ->
        if state.consecutive_failures > 0 do
          # Recovered
          alert_ops(:recovered, state.consecutive_failures)
        end

        schedule_check()
        {:noreply, %{state | consecutive_failures: 0}}

      {:error, reason} ->
        failures = state.consecutive_failures + 1

        if failures >= 3 do
          # Alert after 3 consecutive failures
          alert_ops(:degraded, failures, reason)
        end

        schedule_check()
        {:noreply, %{state | consecutive_failures: failures}}
    end
  end

  defp check_health(conn) do
    case McpClient.Connection.call(conn, "ping", %{}, 5_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check, 30_000)  # Every 30 seconds
  end

  defp alert_ops(status, failures, reason \\ nil) do
    # Send alert to ops team (PagerDuty, Slack, etc.)
    MyApp.Alerts.send(
      "MCP Connection #{status}",
      "Consecutive failures: #{failures}, reason: #{inspect(reason)}"
    )
  end
end
```

---

## Security Best Practices

### Credential Rotation

**Pattern:** Automatically rotate OAuth tokens.

```elixir
defmodule MyApp.MCP.CredentialRotator do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    rotation_interval = Keyword.get(opts, :rotation_interval, :timer.hours(1))

    schedule_rotation(rotation_interval)

    {:ok, %{conn: conn, interval: rotation_interval}}
  end

  def handle_info(:rotate, state) do
    # Get new credentials
    new_oauth = fetch_new_credentials()

    # Restart connection with new credentials
    :ok = McpClient.stop(state.conn)

    {:ok, new_conn} = McpClient.start_link(
      name: MyApp.MCPConnection,
      transport: {McpClient.Transports.HTTP,
                  base_url: "https://mcp.example.com",
                  oauth: new_oauth}
    )

    schedule_rotation(state.interval)
    {:noreply, %{state | conn: new_conn}}
  end

  defp schedule_rotation(interval) do
    Process.send_after(self(), :rotate, interval)
  end

  defp fetch_new_credentials do
    # Fetch from secrets manager
    %{
      client_id: System.get_env("MCP_CLIENT_ID"),
      client_secret: fetch_from_vault("mcp_client_secret"),
      token_url: System.get_env("MCP_TOKEN_URL")
    }
  end

  defp fetch_from_vault(key) do
    # Integration with Vault, AWS Secrets Manager, etc.
    MyApp.SecretsManager.get(key)
  end
end
```

### Request Signing

**Pattern:** Sign requests for additional security.

```elixir
defmodule MyApp.MCP.SecureWrapper do
  def call_tool(conn, tool, args) do
    # Add signature to arguments
    signed_args = Map.put(args, "_signature", sign_request(tool, args))

    McpClient.Tools.call(conn, tool, signed_args)
  end

  defp sign_request(tool, args) do
    secret = Application.get_env(:my_app, :request_secret)
    payload = Jason.encode!(%{tool: tool, args: args, timestamp: System.system_time(:second)})

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode64()
  end
end
```

---

## References

- [Getting Started](GETTING_STARTED.md) - Basic usage
- [Configuration Guide](CONFIGURATION.md) - Complete configuration reference
- [Error Handling Guide](ERROR_HANDLING.md) - Error handling patterns
- [API Reference](https://hexdocs.pm/mcp_client) - Complete API documentation

---

**Questions?** See [FAQ](FAQ.md) or open an issue on GitHub.
