# Code Execution Pattern for MCP Clients

**Date:** 2025-11-07
**Status:** Reference Architecture
**Related:** ADR-0011 (Client Features Architecture), ADVANCED_PATTERNS.md

## Overview

As MCP adoption scales, agents connecting to hundreds or thousands of tools face two critical challenges:
1. **Tool definitions overload context** - Loading all tool definitions upfront consumes excessive tokens
2. **Intermediate results consume tokens** - Every tool result flows through the model's context window

The **code execution pattern** addresses both challenges by treating MCP servers as code APIs rather than direct tool calls. Instead of loading all tools upfront and orchestrating every call through the model, agents write code that interacts with MCP servers programmatically.

**Key Insight:** Our MCP Client is the foundation layer that enables both patterns.

---

## Architecture: Two Usage Patterns

### Pattern A: Direct Tool Calls (Traditional)

**When to use:** < 50 tools, simple workflows, one-off scripts

**Architecture:**
```
┌─────────────┐
│    Agent    │
│   (Model)   │
└──────┬──────┘
       │ Load all tool definitions (10K-150K tokens)
       │ Call tools one at a time
       │ Pass results through context
       ↓
┌─────────────────┐
│  MCP Client     │
│  (mcp_client)   │
└──────┬──────────┘
       │ JSON-RPC over transport
       ↓
┌─────────────────┐
│   MCP Servers   │
│ (stdio/HTTP)    │
└─────────────────┘
```

**Elixir example:**
```elixir
# Agent loads all tools upfront
{:ok, tools} = McpClient.Tools.list(conn)
# => [Tool{name: "gdrive.getDocument", ...}, Tool{name: "salesforce.updateRecord", ...}, ...]
# (Consumes: ~150K tokens for 1000 tools)

# Agent calls tools directly, results flow through context
{:ok, doc} = McpClient.Tools.call(conn, "gdrive.getDocument", %{documentId: "abc123"})
# => %{content: [%{type: "text", text: "Full transcript...(50K tokens)..."}]}
# (Model sees entire result)

{:ok, _} = McpClient.Tools.call(conn, "salesforce.updateRecord", %{
  objectType: "SalesMeeting",
  recordId: "00Q5f000001abcXYZ",
  data: %{Notes: doc.content.text}  # Model writes full text again
})
# (Transcript flows through context twice = 100K tokens)
```

**Token usage:** ~250K tokens (150K definitions + 100K data)

### Pattern B: Code Execution (Scalable)

**When to use:** 100+ tools, complex workflows, production agents

**Architecture:**
```
┌─────────────┐
│    Agent    │
│   (Model)   │
└──────┬──────┘
       │ Discovers tools progressively (filesystem/search)
       │ Writes code to interact with tools
       │ Only sees filtered results
       ↓
┌─────────────────────────┐
│  Code Execution Env     │
│  (Generated Modules)    │
└──────┬──────────────────┘
       │ Calls MCP Client library
       ↓
┌─────────────────┐
│  MCP Client     │
│  (mcp_client)   │
└──────┬──────────┘
       │ JSON-RPC over transport
       ↓
┌─────────────────┐
│   MCP Servers   │
│ (stdio/HTTP)    │
└─────────────────┘
```

**Elixir example:**
```elixir
# Generated modules from tool definitions (done once, not per-request)
# lib/mcp_servers/google_drive.ex
defmodule MCPServers.GoogleDrive do
  def get_document(conn, document_id) do
    McpClient.Connection.call(conn, "google_drive__get_document",
                              %{documentId: document_id})
  end
end

# lib/mcp_servers/salesforce.ex
defmodule MCPServers.Salesforce do
  def update_record(conn, object_type, record_id, data) do
    McpClient.Connection.call(conn, "salesforce__update_record",
                              %{objectType: object_type, recordId: record_id, data: data})
  end
end

# Agent discovers tools by exploring modules (only 2K tokens)
modules = Code.all_loaded()
|> Enum.filter(fn {mod, _} -> Module.split(mod) |> List.first() == "MCPServers" end)
|> Enum.map(fn {mod, _} -> mod.__info__(:functions) end)

# Agent writes code (executes in sandbox)
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

# Data flows through execution environment, not model context
{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
transcript = doc.content  # Full 50K token transcript in memory, NOT in model context

# Agent only sees confirmation, not full data
{:ok, _} = Salesforce.update_record(conn, "SalesMeeting", "00Q5f000001abcXYZ",
                                    %{Notes: transcript})
IO.puts("Updated successfully")  # Model sees: "Updated successfully" (3 tokens)
```

**Token usage:** ~2K tokens (98.7% reduction!)

---

## Comparison: Direct vs Code Execution

| Aspect | Direct Tool Calls | Code Execution |
|--------|------------------|----------------|
| **Tool Discovery** | Load all definitions upfront | Progressive (filesystem/search) |
| **Context Usage** | 10K-150K tokens for definitions | 1K-5K tokens for discovery |
| **Data Flow** | Through model context | Through execution environment |
| **Intermediate Results** | Model sees everything | Model sees filtered output |
| **Control Flow** | Serialized tool calls | Loops, conditionals in code |
| **Token Efficiency** | ~250K tokens (example) | ~2K tokens (98.7% reduction) |
| **Latency** | Multiple model round-trips | Single code execution |
| **Complexity** | Simple (library handles all) | Requires code execution environment |
| **Best For** | < 50 tools, simple workflows | 100+ tools, complex workflows |
| **Implementation** | Built-in (PROMPT_01-15) | Requires code generation (post-MVP) |

**Real-world impact:**
- **Anthropic example:** 150K tokens → 2K tokens (98.7% reduction)
- **Cost savings:** ~$0.30 → $0.004 per request (Claude Sonnet 3.5)
- **Latency improvement:** Multiple round-trips → single execution

---

## How MCP Client Supports Both Patterns

### Our Client is the Foundation Layer

MCP Client provides the **protocol implementation** that both patterns build on:

```elixir
# Core API used by both patterns:
McpClient.Connection.call(conn, method, params, timeout)
McpClient.Connection.notify(conn, method, params)
```

**Pattern A (Direct)** uses high-level wrappers:
```elixir
McpClient.Tools.call(conn, "search", %{query: "test"})
# Internally calls: Connection.call(conn, "tools/call", %{name: "search", arguments: %{query: "test"}})
```

**Pattern B (Code)** uses the same core, via generated modules:
```elixir
MCPServers.GoogleDrive.search(conn, "test")
# Internally calls: Connection.call(conn, "google_drive__search", %{query: "test"})
```

**Both patterns use the same:**
- Transport layer (stdio, SSE, HTTP)
- Connection management (state machine, backoff, retry)
- Error handling and normalization
- Request/response correlation

### Dual-Use Client Features

Our feature modules (PROMPT_10-15) serve both patterns:

**Direct use:**
```elixir
# User calls directly
{:ok, tools} = McpClient.Tools.list(conn)
```

**Code generation use:**
```elixir
# mix mcp.gen.server uses internally
defmodule Mix.Tasks.Mcp.Gen.Server do
  def run([server_name | _]) do
    {:ok, conn} = McpClient.start_link(...)
    {:ok, tools} = McpClient.Tools.list(conn)  # Used to generate modules

    Enum.each(tools, fn tool ->
      generate_module(server_name, tool)
    end)
  end
end
```

---

## Progressive Tool Discovery

Instead of loading all tools upfront, agents discover tools progressively.

### Approach 1: Filesystem Navigation

Generate tool modules as files:
```
lib/mcp_servers/
├── google_drive/
│   ├── get_document.ex
│   ├── list_files.ex
│   └── search.ex
├── salesforce/
│   ├── update_record.ex
│   ├── create_lead.ex
│   └── query.ex
└── slack/
    ├── post_message.ex
    └── get_channel_history.ex
```

Agent explores filesystem:
```elixir
# List available servers
servers = File.ls!("lib/mcp_servers")
# => ["google_drive", "salesforce", "slack"]

# List tools in a server
gdrive_tools = File.ls!("lib/mcp_servers/google_drive")
# => ["get_document.ex", "list_files.ex", "search.ex"]

# Read specific tool definition
tool_code = File.read!("lib/mcp_servers/google_drive/get_document.ex")
# Agent sees only what it needs
```

### Approach 2: Search API (Post-MVP)

Add search capability to find relevant tools:

```elixir
# Search across all connected servers
{:ok, results} = McpClient.Tools.search(conn, "salesforce update", detail: :name_only)
# => ["salesforce__update_record", "salesforce__update_lead"]

{:ok, results} = McpClient.Tools.search(conn, "salesforce update", detail: :full)
# => [%Tool{name: "salesforce__update_record", inputSchema: {...}, ...}]

# Detail levels:
# - :name_only -> Just tool names (100 tokens)
# - :summary -> Names + descriptions (500 tokens)
# - :full -> Complete schemas (2K tokens)
```

Implementation:
```elixir
defmodule McpClient.Tools do
  @spec search(pid(), String.t(), Keyword.t()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def search(conn, query, opts \\ []) do
    # Get all tools (cached)
    {:ok, all_tools} = list(conn)

    # Filter by query (server name, tool name, description)
    matching = Enum.filter(all_tools, fn tool ->
      String.contains?(String.downcase(tool.name), String.downcase(query)) or
      String.contains?(String.downcase(tool.description || ""), String.downcase(query))
    end)

    # Return at requested detail level
    detail = Keyword.get(opts, :detail, :full)
    filtered = filter_by_detail(matching, detail)

    {:ok, filtered}
  end

  defp filter_by_detail(tools, :name_only) do
    Enum.map(tools, & %{name: &1.name})
  end

  defp filter_by_detail(tools, :summary) do
    Enum.map(tools, & %{name: &1.name, description: &1.description})
  end

  defp filter_by_detail(tools, :full), do: tools
end
```

---

## Context-Efficient Data Processing

Code execution enables data transformation before results reach the model.

### Example: Large Dataset Filtering

**Without code execution:**
```elixir
# All 10,000 rows flow through model context
{:ok, sheet} = McpClient.Resources.read(conn, "sheet://abc123")
# Model receives entire sheet: 10,000 rows × 50 tokens/row = 500K tokens

# Model must filter in its context
pending = Enum.filter(sheet.rows, fn row -> row["Status"] == "pending" end)
```

**With code execution:**
```elixir
# Agent writes code that filters before returning
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "abc123")
pending = Enum.filter(sheet.rows, fn row -> row["Status"] == "pending" end)

IO.puts("Found #{length(pending)} pending orders")
IO.inspect(Enum.take(pending, 5), label: "Sample")
# Model sees: "Found 47 pending orders" + 5 rows = ~250 tokens (99.95% reduction)
```

### Example: Aggregations

**Without code execution:**
```elixir
# Full dataset in context for aggregation
{:ok, sales} = McpClient.Tools.call(conn, "salesforce.query", %{
  query: "SELECT Amount, CloseDate FROM Opportunity LIMIT 10000"
})
# 10,000 records in context

# Model aggregates
total = Enum.sum(Enum.map(sales.records, & &1["Amount"]))
```

**With code execution:**
```elixir
# Aggregation happens in execution environment
{:ok, sales} = MCPServers.Salesforce.query(conn,
  "SELECT Amount, CloseDate FROM Opportunity LIMIT 10000")

total = Enum.sum(Enum.map(sales.records, & &1["Amount"]))
by_month = Enum.group_by(sales.records, fn r ->
  Date.from_iso8601!(r["CloseDate"]) |> Date.beginning_of_month()
end)

IO.puts("Total: $#{total}")
IO.inspect(Map.keys(by_month), label: "Months with sales")
# Model sees: "Total: $1,234,567" + list of months = ~50 tokens
```

---

## Control Flow in Code

Loops, conditionals, and error handling use familiar code patterns.

### Polling Example

**Without code execution (inefficient):**
```
AGENT: Call slack.getChannelHistory
RESULT: [...messages...]
AGENT: Check if "deployment complete" in messages
AGENT: Not found. Wait 5 seconds.
[5 seconds pass]
AGENT: Call slack.getChannelHistory
RESULT: [...messages...]
[Repeat until found]
```

Each iteration is a model round-trip (latency + cost).

**With code execution:**
```elixir
# Agent writes polling code once
deployment_complete = fn ->
  Stream.repeatedly(fn ->
    {:ok, messages} = MCPServers.Slack.get_channel_history(conn, "C123456")
    found = Enum.any?(messages, fn m -> String.contains?(m.text, "deployment complete") end)

    if found do
      {:halt, true}
    else
      Process.sleep(5000)
      {:cont, false}
    end
  end)
  |> Enum.take_while(fn result -> result == {:cont, false} end)
end

deployment_complete.()
IO.puts("Deployment notification received")
```

Single execution, no model round-trips during polling.

### Conditional Trees

**Without code execution:**
```
AGENT: Call gdrive.getDocument
RESULT: {...}
AGENT: Call salesforce.query to check if lead exists
RESULT: {...}
AGENT: If lead exists, call salesforce.updateRecord
AGENT: Else, call salesforce.createLead
[Multiple round-trips for each condition]
```

**With code execution:**
```elixir
# Agent writes conditional tree
{:ok, doc} = MCPServers.GoogleDrive.get_document(conn, "abc123")

{:ok, leads} = MCPServers.Salesforce.query(conn,
  "SELECT Id FROM Lead WHERE Email = '#{doc.email}'")

if Enum.empty?(leads.records) do
  {:ok, _} = MCPServers.Salesforce.create_lead(conn, %{
    Email: doc.email,
    Company: doc.company,
    Notes: doc.notes
  })
  IO.puts("Created new lead")
else
  lead_id = List.first(leads.records)["Id"]
  {:ok, _} = MCPServers.Salesforce.update_record(conn, "Lead", lead_id, %{
    Notes: doc.notes
  })
  IO.puts("Updated existing lead")
end
```

Conditional logic executes without model involvement.

---

## Privacy-Preserving Operations

Sensitive data can flow through workflows without entering model context.

### Example: PII Handling

**Problem:** Agent needs to sync customer data from spreadsheet to Salesforce, but shouldn't see PII.

**Solution with tokenization:**

```elixir
# Agent writes sync code
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "abc123")

# MCP Client intercepts and tokenizes PII before agent sees it
# Agent sees:
# [
#   %{email: "[EMAIL_1]", phone: "[PHONE_1]", name: "[NAME_1]", salesforce_id: "00Q..."},
#   %{email: "[EMAIL_2]", phone: "[PHONE_2]", name: "[NAME_2]", salesforce_id: "00Q..."},
# ]

Enum.each(sheet.rows, fn row ->
  MCPServers.Salesforce.update_record(conn, "Lead", row.salesforce_id, %{
    Email: row.email,      # Tokens sent to Salesforce
    Phone: row.phone,      # MCP Client untokenizes on send
    Name: row.name
  })
end)

IO.puts("Synced #{length(sheet.rows)} leads")
# Agent sees: "Synced 1000 leads" (no PII)
```

**MCP Client tokenization layer** (post-MVP feature):
```elixir
defmodule McpClient.Tokenizer do
  @moduledoc """
  Tokenizes sensitive data before model sees it, untokenizes before sending to servers.
  """

  def tokenize_response(response, rules) do
    # Apply tokenization rules (email, phone, SSN, etc.)
    # Store mapping: token -> original value
    # Return tokenized response
  end

  def untokenize_request(request, token_map) do
    # Replace tokens with original values
    # Return untokenized request
  end
end
```

---

## Skills: Reusable Agent Code

Code execution enables agents to save and reuse working code.

### Skill Structure

```
lib/skills/
├── export_sheet_to_csv/
│   ├── SKILL.md           # Description, usage, examples
│   └── export.ex          # Implementation
├── bulk_update_salesforce/
│   ├── SKILL.md
│   └── update.ex
└── summarize_meeting/
    ├── SKILL.md
    └── summarize.ex
```

### Creating a Skill

**Agent develops working code:**
```elixir
# First time agent solves a problem
{:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, "abc123")
csv = Enum.map_join(sheet.rows, "\n", fn row ->
  Enum.map_join(row, ",", & &1)
end)
File.write!("output.csv", csv)
```

**Save as reusable skill:**
```elixir
# lib/skills/export_sheet_to_csv/export.ex
defmodule Skills.ExportSheetToCsv do
  @moduledoc """
  Export a Google Sheet to CSV format.
  """

  def run(conn, sheet_id, output_path) do
    {:ok, sheet} = MCPServers.GoogleDrive.get_sheet(conn, sheet_id)
    csv = Enum.map_join(sheet.rows, "\n", fn row ->
      Enum.map_join(row, ",", & &1)
    end)
    File.write!(output_path, csv)
    {:ok, output_path}
  end
end
```

```markdown
# lib/skills/export_sheet_to_csv/SKILL.md

# Export Sheet to CSV

Export a Google Sheet to CSV format.

## Usage

```elixir
Skills.ExportSheetToCsv.run(conn, "sheet-id", "output.csv")
```

## Parameters

- `conn` - MCP connection
- `sheet_id` - Google Sheet ID
- `output_path` - Path for output CSV file

## Returns

`{:ok, output_path}` on success
```

### Using Skills

**Agent discovers available skills:**
```elixir
# List skills
skills = File.ls!("lib/skills")
# => ["export_sheet_to_csv", "bulk_update_salesforce", "summarize_meeting"]

# Read skill documentation
skill_doc = File.read!("lib/skills/export_sheet_to_csv/SKILL.md")
# Agent learns how to use skill
```

**Agent uses skill:**
```elixir
# Import skill module
alias Skills.ExportSheetToCsv

# Use in workflow
{:ok, csv_path} = ExportSheetToCsv.run(conn, "abc123", "data.csv")
IO.puts("Exported to #{csv_path}")

# Compose with other operations
{:ok, csv_path} = ExportSheetToCsv.run(conn, "abc123", "data.csv")
csv_data = File.read!(csv_path)
# Process CSV data...
```

---

## Implementation Considerations

### Security: Code Execution Sandbox

Running agent-generated code requires secure sandboxing:

**Requirements:**
- Isolated execution environment (Docker, Firecracker, etc.)
- Resource limits (CPU, memory, disk, network)
- Time limits (prevent infinite loops)
- Filesystem access controls
- Network access controls (only MCP servers)

**Elixir sandbox options:**
1. **Separate BEAM node** - Run code in separate node, communicate via distribution
2. **Docker containers** - Spin up container per execution
3. **Firecracker microVMs** - Ultra-lightweight VMs for isolation

**Example: Docker sandbox**
```elixir
defmodule McpClient.Sandbox do
  def execute(code, conn_config) do
    # Write code to temp file
    code_path = write_temp_file(code)

    # Run in Docker with limits
    {output, exit_code} = System.cmd("docker", [
      "run",
      "--rm",
      "--network", "host",  # For MCP server access
      "--cpus", "1.0",
      "--memory", "512m",
      "--read-only",
      "mcp-agent-sandbox",
      "elixir", code_path
    ], env: [{"MCP_CONN", Jason.encode!(conn_config)}])

    if exit_code == 0 do
      {:ok, output}
    else
      {:error, output}
    end
  end
end
```

### Performance: Code Generation

Generating modules from tool definitions:

**When to generate:**
- At deployment time (pre-generate all connected servers)
- On-demand (generate when first accessed)
- Hybrid (pre-generate common servers, on-demand for others)

**Generation strategy:**
```elixir
defmodule Mix.Tasks.Mcp.Gen.Server do
  def run([server_name | args]) do
    # Connect to server
    {:ok, conn} = McpClient.start_link(
      transport: build_transport(server_name, args)
    )

    # Get tool definitions
    {:ok, tools} = McpClient.Tools.list(conn)

    # Generate module per tool
    Enum.each(tools, fn tool ->
      module_code = generate_tool_module(server_name, tool)
      output_path = "lib/mcp_servers/#{server_name}/#{tool.name}.ex"
      File.write!(output_path, module_code)
    end)

    # Generate server module (aggregates all tools)
    server_module = generate_server_module(server_name, tools)
    File.write!("lib/mcp_servers/#{server_name}.ex", server_module)

    IO.puts("Generated #{length(tools)} tools for #{server_name}")
  end

  defp generate_tool_module(server, tool) do
    """
    defmodule MCPServers.#{Macro.camelize(server)}.#{Macro.camelize(tool.name)} do
      @moduledoc \"\"\"
      #{tool.description || "Tool: #{tool.name}"}

      ## Input Schema
      #{Jason.encode!(tool.inputSchema, pretty: true)}
      \"\"\"

      def call(conn, args) do
        McpClient.Connection.call(conn, "#{server}__#{tool.name}", args)
      end
    end
    """
  end
end
```

### Caching: Tool Definitions

Cache generated modules to avoid regeneration:

```elixir
# Cache generated modules
defmodule McpClient.CodeGen.Cache do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get(server_name, tool_name) do
    Agent.get(__MODULE__, fn cache ->
      Map.get(cache, {server_name, tool_name})
    end)
  end

  def put(server_name, tool_name, module_code) do
    Agent.update(__MODULE__, fn cache ->
      Map.put(cache, {server_name, tool_name}, module_code)
    end)
  end
end
```

---

## Migration Path

### Phase 1: Direct Tool Calls (MVP)

Start with direct tool calls:
```elixir
{:ok, conn} = McpClient.start_link(...)
{:ok, tools} = McpClient.Tools.list(conn)
{:ok, result} = McpClient.Tools.call(conn, "search", %{query: "test"})
```

**Works well for:**
- < 50 tools
- Simple workflows
- Prototyping
- CLI tools

### Phase 2: Manual Code Generation (Post-MVP)

Generate modules manually for high-traffic servers:
```bash
mix mcp.gen.server google_drive --output lib/mcp_servers/
mix mcp.gen.server salesforce --output lib/mcp_servers/
```

Agent uses generated modules:
```elixir
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
{:ok, _} = Salesforce.update_record(conn, "Lead", "00Q...", %{Notes: doc.content})
```

**Works well for:**
- 50-200 tools
- Frequently used servers
- Performance-critical paths

### Phase 3: Full Code Execution (Future)

Agent writes and executes code in sandbox:
```elixir
# Agent generates code
code = """
alias MCPServers.GoogleDrive
alias MCPServers.Salesforce

{:ok, doc} = GoogleDrive.get_document(conn, "abc123")
# ... complex workflow ...
"""

# Execute in sandbox
{:ok, output} = McpClient.Sandbox.execute(code, conn)
```

**Works well for:**
- 200+ tools
- Complex multi-step workflows
- Dynamic tool composition

---

## Comparison with Other Approaches

### TypeScript Example (Anthropic Blog)

Anthropic's example uses filesystem-based discovery:
```typescript
servers/
├── google-drive/
│   ├── getDocument.ts
│   └── index.ts
└── salesforce/
    ├── updateRecord.ts
    └── index.ts
```

**Elixir equivalent:**
```elixir
lib/mcp_servers/
├── google_drive/
│   ├── get_document.ex
│   └── google_drive.ex
└── salesforce/
    ├── update_record.ex
    └── salesforce.ex
```

Both approaches:
- ✅ Progressive tool discovery
- ✅ Type-safe function calls
- ✅ 98%+ token reduction
- ✅ Built on MCP client foundation

### Cloudflare "Code Mode"

Cloudflare's approach is similar but emphasizes the performance benefits. Both recognize that **LLMs are excellent at writing code** and leverage this strength.

**Key insight:** The pattern is language-agnostic—works in TypeScript, Python, Elixir, etc.

---

## Future Enhancements

### Post-MVP Features

**1. Progressive Tool Discovery API**
```elixir
McpClient.Tools.search(conn, "salesforce", detail: :name_only)
```

**2. Code Generation Tool**
```bash
mix mcp.gen.server google_drive
```

**3. Sandbox Execution**
```elixir
McpClient.Sandbox.execute(code, conn)
```

**4. PII Tokenization**
```elixir
McpClient.Tokenizer.tokenize_response(response, rules)
```

**5. Skills Pattern**
```elixir
McpClient.Skills.save("export_csv", code)
McpClient.Skills.list()
```

**6. Tool Caching**
```elixir
McpClient.CodeGen.Cache.get(server, tool)
```

---

## References

- **Anthropic Blog**: "Code execution with MCP: Building more efficient agents" (Nov 2025)
- **Cloudflare**: "Code Mode" MCP implementation
- **ADR-0011**: Client Features Architecture
- **ADVANCED_PATTERNS.md**: Implementation patterns
- **MCP Specification**: https://spec.modelcontextprotocol.io/

---

## Summary

The code execution pattern represents a fundamental shift in how agents interact with MCP servers:

**Traditional approach:**
- Load all tools → Agent orchestrates → Every result through context
- Works for < 50 tools
- High token cost, high latency

**Code execution approach:**
- Discover progressively → Agent writes code → Filter before context
- Scales to 1000+ tools
- 98%+ token reduction, lower latency

**Our MCP Client enables both:**
- Provides protocol foundation
- Supports direct tool calls (MVP)
- Foundation for code generation (post-MVP)

**Key insight:** We're building the essential transport layer. Code execution is a usage pattern built on top, enabled by our solid foundation.

---

**Status:** Reference architecture for future development
**Next:** Implement MVP (PROMPT_01-15), add code generation post-MVP
