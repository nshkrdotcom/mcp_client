# Implementation Prompt 06: Transport Behavior and Stdio Implementation

**Goal:** Create the Transport behavior contract and stdio transport implementation using Port.

**Test Strategy:** TDD with rgr. All tests green, no warnings.

---

## Context: What You're Building

You're implementing the transport abstraction layer that Connection depends on. This includes:
1. **Transport behavior**: Defines the contract all transports must implement
2. **StdioTransport**: Spawns a subprocess via Port, sends/receives JSON-RPC frames over stdio

The transport is responsible for:
- Managing external process lifecycle
- Sending frames (JSON-RPC messages)
- Receiving frames and delivering to Connection
- Flow control via `set_active/2`
- Clean shutdown

---

## Required Reading: Transport Contract

From ADR-0002 and STATE_TRANSITIONS.md:

### Transport Message Contract

Transport MUST emit exactly these messages to Connection:

```elixir
# Sent once after transport is ready to send/receive
{:transport, :up}

# Sent for each complete frame (only after set_active(:once))
{:transport, :frame, binary()}

# Sent when transport closes or fails
{:transport, :down, reason :: term()}
```

### Transport Behavior API

```elixir
@callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}
@callback send_frame(pid(), binary()) :: :ok | :busy | {:error, term()}
@callback set_active(pid(), :once | false) :: :ok
@callback close(pid()) :: :ok
```

### Key Requirements

**From ADR-0004: Active-Once Backpressure**

1. Transport starts in "paused" mode (no frame delivery)
2. Connection calls `set_active(transport, :once)` to enable delivery of ONE frame
3. After delivering frame, transport auto-pauses
4. Connection must call `set_active(:once)` again for next frame
5. `set_active(pid, false)` explicitly pauses (rarely used)

**Flow:**
```
1. Port receives data → StdioTransport buffers
2. Connection calls set_active(:once)
3. StdioTransport sends {:transport, :frame, binary} to Connection
4. StdioTransport auto-pauses (waits for next set_active)
```

**CRITICAL**: Never call `set_active/2` after `close/1` (Connection's responsibility).

---

## Implementation Requirements

### 1. Transport Behavior

**File: `lib/mcp_client/transport.ex`**

```elixir
defmodule McpClient.Transport do
  @moduledoc """
  Behavior for MCP transport implementations.

  Transports manage communication with MCP servers over various protocols:
  - Stdio: subprocess via Port
  - SSE: Server-Sent Events over HTTP
  - HTTP: Direct HTTP+SSE connection

  ## Message Contract

  Transport implementations MUST send exactly these messages to the
  Connection process:

  - `{:transport, :up}` - Sent once after transport is ready
  - `{:transport, :frame, binary()}` - Complete JSON-RPC frame (only after set_active)
  - `{:transport, :down, reason}` - Transport closed or failed

  ## Flow Control

  Transports start in "paused" mode. The Connection calls `set_active(pid, :once)`
  to enable delivery of ONE frame. After delivering, the transport auto-pauses.

  This prevents mailbox flooding (see ADR-0004).
  """

  @type frame :: binary()
  @type send_result :: :ok | :busy | {:error, term()}

  @doc """
  Start the transport process.

  Options:
  - `:command` - (stdio) Command to execute
  - `:args` - (stdio) Command arguments
  - `:url` - (sse/http) Server URL
  - `:env` - (stdio) Environment variables
  - `:connection` - PID of Connection process (for sending messages)
  """
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc """
  Send a complete JSON-RPC frame to the server.

  Returns:
  - `:ok` - Frame sent successfully
  - `:busy` - Transport buffer full (Connection will retry)
  - `{:error, reason}` - Permanent failure
  """
  @callback send_frame(pid(), frame()) :: send_result()

  @doc """
  Enable or disable frame delivery.

  - `:once` - Deliver next frame, then auto-pause
  - `false` - Pause frame delivery
  """
  @callback set_active(pid(), :once | false) :: :ok

  @doc """
  Close the transport gracefully.

  Must not send any messages after close (including set_active).
  """
  @callback close(pid()) :: :ok
end
```

---

### 2. Stdio Transport Implementation

**File: `lib/mcp_client/transports/stdio.ex`**

```elixir
defmodule McpClient.Transports.Stdio do
  @moduledoc """
  Stdio transport implementation using Erlang Port.

  Spawns a subprocess and communicates via stdin/stdout using JSON-RPC
  frames delimited by newlines.

  ## Frame Delimiting

  MCP over stdio uses newline-delimited JSON (NDJSON):
  - Each frame is a complete JSON-RPC message
  - Frames are separated by '\n'
  - No framing bytes or length prefixes

  ## Backpressure

  Port can push data faster than Connection can process. We use active-once
  to prevent mailbox flooding:
  - Buffer incoming data
  - Only deliver frames when Connection calls set_active(:once)
  - Auto-pause after each delivery
  """

  use GenServer
  require Logger
  @behaviour McpClient.Transport

  defstruct [
    :port,           # Erlang Port
    :connection,     # Connection PID (for sending messages)
    :buffer,         # Incomplete data buffer (binary)
    :queue,          # Complete frames queue (list of binaries)
    :active          # :once | false
  ]

  ## Client API

  @impl true
  def start_link(opts) do
    connection_pid = Keyword.fetch!(opts, :connection)
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def send_frame(pid, frame) do
    GenServer.call(pid, {:send_frame, frame})
  end

  @impl true
  def set_active(pid, mode) when mode in [:once, false] do
    GenServer.cast(pid, {:set_active, mode})
  end

  @impl true
  def close(pid) do
    GenServer.call(pid, :close)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    connection_pid = Keyword.fetch!(opts, :connection)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    # Spawn subprocess via Port
    port_opts = [
      :binary,
      :exit_status,
      {:line, 1024 * 1024},  # 1MB line buffer (frames are newline-delimited)
      {:args, args},
      {:env, format_env(env)}
    ]

    port = Port.open({:spawn_executable, System.find_executable(command)}, port_opts)

    state = %__MODULE__{
      port: port,
      connection: connection_pid,
      buffer: "",
      queue: [],
      active: false
    }

    # Notify Connection that transport is ready
    send(connection_pid, {:transport, :up})

    {:ok, state}
  rescue
    error ->
      Logger.error("Failed to spawn transport: #{inspect(error)}")
      {:stop, {:spawn_failed, error}}
  end

  @impl true
  def handle_call({:send_frame, frame}, _from, state) do
    # Send frame to subprocess (add newline)
    data = frame <> "\n"

    case Port.command(state.port, data) do
      true ->
        {:reply, :ok, state}

      false ->
        # Port closed or busy
        {:reply, {:error, :port_closed}, state}
    end
  rescue
    ArgumentError ->
      # Port already closed
      {:reply, {:error, :port_closed}, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    Port.close(state.port)
    send(state.connection, {:transport, :down, :normal})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:set_active, mode}, state) do
    state = %{state | active: mode}

    # If mode is :once and we have queued frames, deliver one
    state = maybe_deliver_frame(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    # Received complete line (frame)
    state = enqueue_frame(state, line)
    state = maybe_deliver_frame(state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    # Partial line (shouldn't happen with {:line, N} mode, but handle it)
    state = %{state | buffer: state.buffer <> partial}
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Subprocess exited with status #{status}")
    send(state.connection, {:transport, :down, {:exit_status, status}})
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("Port died: #{inspect(reason)}")
    send(state.connection, {:transport, :down, {:port_exit, reason}})
    {:stop, :normal, state}
  end

  ## Helpers

  defp enqueue_frame(state, frame) do
    %{state | queue: state.queue ++ [frame]}
  end

  defp maybe_deliver_frame(%{active: :once, queue: [frame | rest]} = state) do
    # Deliver frame and auto-pause
    send(state.connection, {:transport, :frame, frame})
    %{state | queue: rest, active: false}
  end

  defp maybe_deliver_frame(state) do
    # Either not active, or no frames queued
    state
  end

  defp format_env(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
```

---

### 3. Mock Transport for Testing

**File: `test/support/mock_transport.ex`**

```elixir
defmodule McpClient.MockTransport do
  @moduledoc """
  Mock transport for testing.

  Allows tests to control send behavior (ok, busy, error) and
  simulate transport events (up, down, frame delivery).
  """

  use GenServer
  @behaviour McpClient.Transport

  defstruct [
    :connection,
    :send_behavior,  # :ok | :busy | {:error, term()} | function
    :active,
    :send_count
  ]

  ## Client API

  @impl true
  def start_link(opts) do
    connection_pid = Keyword.fetch!(opts, :connection)
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def send_frame(pid, _frame) do
    GenServer.call(pid, :send_frame)
  end

  @impl true
  def set_active(pid, mode) do
    GenServer.cast(pid, {:set_active, mode})
  end

  @impl true
  def close(pid) do
    GenServer.call(pid, :close)
  end

  ## Test Helpers

  def configure(pid, opts) do
    GenServer.call(pid, {:configure, opts})
  end

  def send_to_connection(pid, msg) do
    GenServer.cast(pid, {:send_to_connection, msg})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    connection_pid = Keyword.fetch!(opts, :connection)
    send_behavior = Keyword.get(opts, :send_behavior, :ok)

    state = %__MODULE__{
      connection: connection_pid,
      send_behavior: send_behavior,
      active: false,
      send_count: 0
    }

    # Notify Connection
    send(connection_pid, {:transport, :up})

    {:ok, state}
  end

  @impl true
  def handle_call(:send_frame, _from, state) do
    result = case state.send_behavior do
      behavior when behavior in [:ok, :busy] -> behavior
      {:error, _} = error -> error
      fun when is_function(fun, 1) -> fun.(state.send_count)
    end

    state = %{state | send_count: state.send_count + 1}
    {:reply, result, state}
  end

  def handle_call(:close, _from, state) do
    send(state.connection, {:transport, :down, :normal})
    {:stop, :normal, :ok, state}
  end

  def handle_call({:configure, opts}, _from, state) do
    send_behavior = Keyword.get(opts, :send_behavior, state.send_behavior)
    state = %{state | send_behavior: send_behavior}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:set_active, mode}, state) do
    state = %{state | active: mode}
    {:noreply, state}
  end

  def handle_cast({:send_to_connection, msg}, state) do
    send(state.connection, msg)
    {:noreply, state}
  end
end
```

---

## Test File: test/mcp_client/transports/stdio_test.exs

```elixir
defmodule McpClient.Transports.StdioTest do
  use ExUnit.Case, async: true
  alias McpClient.Transports.Stdio

  describe "start_link/1" do
    test "spawns subprocess and sends :up message" do
      # Use a simple subprocess that echoes input
      opts = [
        connection: self(),
        command: "cat",  # Echo back whatever we send
        args: []
      ]

      {:ok, pid} = Stdio.start_link(opts)

      # Should receive :up message
      assert_receive {:transport, :up}, 1000

      Stdio.close(pid)
    end

    test "returns error for invalid command" do
      opts = [
        connection: self(),
        command: "nonexistent_command_xyz",
        args: []
      ]

      assert {:error, _} = Stdio.start_link(opts)
    end
  end

  describe "send_frame/2" do
    setup do
      {:ok, pid} = Stdio.start_link(
        connection: self(),
        command: "cat",
        args: []
      )

      assert_receive {:transport, :up}

      {:ok, transport: pid}
    end

    test "sends frame to subprocess", %{transport: pid} do
      frame = ~s({"jsonrpc":"2.0","method":"ping"})

      assert :ok = Stdio.send_frame(pid, frame)

      # Enable delivery
      Stdio.set_active(pid, :once)

      # Should receive echoed frame (cat echoes back)
      assert_receive {:transport, :frame, received}, 1000
      assert received =~ "ping"

      Stdio.close(pid)
    end
  end

  describe "set_active/2" do
    setup do
      # Use a subprocess that sends test data
      # For simplicity, use echo or printf
      {:ok, pid} = Stdio.start_link(
        connection: self(),
        command: "printf",
        args: ["test frame\n"]
      )

      assert_receive {:transport, :up}

      {:ok, transport: pid}
    end

    test "delivers one frame then pauses", %{transport: pid} do
      # Set active once
      Stdio.set_active(pid, :once)

      # Should receive one frame
      assert_receive {:transport, :frame, "test frame"}, 1000

      # Should not receive more (auto-paused)
      refute_receive {:transport, :frame, _}, 100

      Stdio.close(pid)
    end

    test "set_active(false) pauses delivery", %{transport: pid} do
      Stdio.set_active(pid, false)

      # Should not receive frames
      refute_receive {:transport, :frame, _}, 100

      Stdio.close(pid)
    end
  end

  describe "close/1" do
    test "closes port and sends :down message" do
      {:ok, pid} = Stdio.start_link(
        connection: self(),
        command: "cat",
        args: []
      )

      assert_receive {:transport, :up}

      assert :ok = Stdio.close(pid)

      # Should receive :down
      assert_receive {:transport, :down, :normal}, 1000
    end
  end

  describe "subprocess exit" do
    test "sends :down on subprocess exit" do
      # Use a command that exits immediately
      {:ok, pid} = Stdio.start_link(
        connection: self(),
        command: "true",  # Exits with status 0
        args: []
      )

      assert_receive {:transport, :up}

      # Should receive :down when process exits
      assert_receive {:transport, :down, {:exit_status, 0}}, 1000
    end

    test "sends :down on subprocess crash" do
      {:ok, pid} = Stdio.start_link(
        connection: self(),
        command: "false",  # Exits with status 1
        args: []
      )

      assert_receive {:transport, :up}

      assert_receive {:transport, :down, {:exit_status, 1}}, 1000
    end
  end
end
```

---

## Success Criteria

Run tests with:
```bash
mix test test/mcp_client/transports/stdio_test.exs
```

**Must achieve:**
- ✅ All tests pass (green)
- ✅ No warnings
- ✅ Transport behavior defined correctly
- ✅ Stdio transport spawns subprocess
- ✅ Active-once flow control works
- ✅ Port closes cleanly
- ✅ Messages sent to Connection correctly

---

## Constraints

- **DO NOT** implement SSE or HTTP transports yet (post-MVP)
- **DO NOT** add features beyond spec
- Use exact message shapes: `{:transport, :up}`, etc.
- Port mode: `{:line, 1024 * 1024}` for newline-delimited frames
- No buffering beyond one frame in queue (MVP)

---

## Implementation Notes

### Port vs GenServer

We use `Port.open/2` with `GenServer` wrapper:
- Port handles subprocess I/O
- GenServer handles state management and flow control
- GenServer receives Port messages (`:data`, `:exit_status`)

### Frame Delimiting

MCP over stdio uses newline-delimited JSON (NDJSON):
- Send: append `\n` to frame
- Receive: Port with `{:line, N}` splits on newlines automatically

### Backpressure Implementation

1. Port delivers data to GenServer mailbox
2. GenServer queues complete frames
3. Only when `active: :once`, deliver first frame to Connection
4. Auto-set `active: false` after delivery
5. Connection calls `set_active(:once)` for next frame

**Queue size**: MVP uses unbounded list. Post-MVP could add max queue size and return `:busy` on send.

### Error Handling

**Port failure scenarios:**
- Command not found: `init` returns `{:stop, reason}`
- Subprocess crashes: Receive `:exit_status`, send `:down` to Connection
- Port closed: `Port.command` returns `false` or raises

### Environment Variables

Format for Port:
```elixir
{:env, [{'PATH', '/usr/bin'}, {'HOME', '/home/user'}]}
```

Use charlists, not binaries.

### Testing with Real Subprocesses

Use simple Unix commands:
- `cat` - echoes stdin to stdout
- `printf "data\n"` - sends test data
- `true` / `false` - exit with status 0/1

For full MCP testing, use a mock MCP server subprocess (later prompt).

---

## Deliverable

Provide:
1. `lib/mcp_client/transport.ex` - Behavior definition
2. `lib/mcp_client/transports/stdio.ex` - Stdio implementation
3. `test/support/mock_transport.ex` - Mock for testing
4. `test/mcp_client/transports/stdio_test.exs` - Tests

All files must:
- Compile without warnings
- Pass all tests
- Follow exact message contract
- Implement active-once correctly

If any requirement is unclear, insert `# TODO: <reason>` and stop.
