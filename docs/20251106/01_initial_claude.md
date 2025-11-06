```
mcp_client/
├── mix.exs
├── README.md
├── LICENSE
├── .formatter.exs
├── config/
│   └── config.exs
├── lib/
│   ├── mcp_client.ex                          # Main public API
│   ├── mcp_client/
│   │   ├── application.ex                     # OTP Application
│   │   ├── client.ex                          # GenServer managing connection lifecycle
│   │   ├── types.ex                           # Protocol types & structs
│   │   ├── protocol/
│   │   │   ├── jsonrpc.ex                    # JSON-RPC 2.0 encoding/decoding
│   │   │   ├── initialize.ex                 # Initialize handshake
│   │   │   ├── ping.ex                       # Ping/health checks
│   │   │   └── logging.ex                    # Logging notifications
│   │   ├── features/
│   │   │   ├── resources.ex                  # Resource management
│   │   │   ├── prompts.ex                    # Prompt management
│   │   │   ├── tools.ex                      # Tool invocation
│   │   │   ├── sampling.ex                   # LLM sampling requests
│   │   │   └── roots.ex                      # Root directory management
│   │   ├── transport/
│   │   │   ├── behaviour.ex                  # Transport behaviour
│   │   │   ├── stdio.ex                      # Standard I/O transport
│   │   │   ├── sse.ex                        # Server-Sent Events transport
│   │   │   └── http.ex                       # HTTP with SSE transport
│   │   ├── connection/
│   │   │   ├── supervisor.ex                 # Supervises client connections
│   │   │   ├── state.ex                      # Connection state machine
│   │   │   └── registry.ex                   # Client registry
│   │   ├── request/
│   │   │   ├── manager.ex                    # Manages pending requests
│   │   │   └── tracker.ex                    # Tracks request/response correlation
│   │   ├── subscription/
│   │   │   ├── manager.ex                    # Resource subscription management
│   │   │   └── store.ex                      # ETS-based subscription storage
│   │   ├── middleware/
│   │   │   ├── telemetry.ex                  # Telemetry instrumentation
│   │   │   ├── logging.ex                    # Request/response logging
│   │   │   └── retry.ex                      # Retry logic
│   │   └── errors.ex                         # Error definitions & handling
│   └── mix/
│       └── tasks/
│           └── mcp.gen.server.ex            # Mix task to generate MCP server scaffolds
├── test/
│   ├── test_helper.exs
│   ├── mcp_client_test.exs
│   ├── mcp_client/
│   │   ├── client_test.exs
│   │   ├── protocol/
│   │   │   ├── jsonrpc_test.exs
│   │   │   └── initialize_test.exs
│   │   ├── features/
│   │   │   ├── resources_test.exs
│   │   │   ├── prompts_test.exs
│   │   │   └── tools_test.exs
│   │   └── transport/
│   │       ├── stdio_test.exs
│   │       └── sse_test.exs
│   └── support/
│       ├── mock_server.ex
│       └── fixtures.ex
└── examples/
    ├── simple_client.exs
    ├── tool_calling.exs
    ├── resource_subscription.exs
    └── sampling_workflow.exs
```

```elixir
# lib/mcp_client.ex
defmodule McpClient do
  @moduledoc """
  Elixir client library for the Model Context Protocol (MCP).
  
  MCP is a protocol that enables AI applications to securely access context from
  various sources. This library provides a complete implementation of the MCP 
  specification including:
  
  - **Transport layers**: stdio, SSE, HTTP+SSE
  - **Resources**: List, read, subscribe to resource updates
  - **Prompts**: List and retrieve prompt templates
  - **Tools**: List and invoke server-provided tools
  - **Sampling**: Request LLM completions from clients
  - **Roots**: Manage root directories for file access
  - **Logging**: Receive and emit structured logs
  
  ## Installation
  
  Add `mcp_client` to your dependencies in `mix.exs`:
  
      def deps do
        [
          {:mcp_client, "~> 0.1.0"}
        ]
      end
  
  ## Quick Start
  
      # Start a client with stdio transport
      {:ok, client} = McpClient.start_link(
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        client_info: %{
          name: "my-elixir-app",
          version: "1.0.0"
        }
      )
      
      # Wait for initialization
      :ok = McpClient.await_initialized(client)
      
      # List available resources
      {:ok, resources} = McpClient.list_resources(client)
      
      # Read a resource
      {:ok, contents} = McpClient.read_resource(client, "file:///tmp/example.txt")
      
      # List available tools
      {:ok, tools} = McpClient.list_tools(client)
      
      # Call a tool
      {:ok, result} = McpClient.call_tool(client, "read_file", %{
        path: "/tmp/example.txt"
      })
      
      # Clean shutdown
      McpClient.stop(client)
  
  ## Architecture
  
  The client is implemented as an OTP GenServer with the following components:
  
  - **Client GenServer**: Manages connection lifecycle and state
  - **Transport Layer**: Handles protocol-specific communication (stdio, SSE, HTTP)
  - **Request Manager**: Tracks pending requests and correlates responses
  - **Subscription Manager**: Manages resource subscriptions and notifications
  - **Middleware Pipeline**: Telemetry, logging, retry logic
  
  ## Configuration
  
  Global configuration can be set in `config/config.exs`:
  
      config :mcp_client,
        default_timeout: 30_000,
        default_retry_attempts: 3,
        telemetry_prefix: [:mcp_client],
        log_level: :info
  
  ## Transport Options
  
  ### Standard I/O (stdio)
  
      McpClient.start_link(
        transport: :stdio,
        command: "python",
        args: ["-m", "my_mcp_server"],
        env: %{"API_KEY" => "secret"}
      )
  
  ### Server-Sent Events (SSE)
  
      McpClient.start_link(
        transport: :sse,
        url: "http://localhost:3000/sse",
        headers: [{"authorization", "Bearer token"}]
      )
  
  ### HTTP with SSE
  
      McpClient.start_link(
        transport: :http_sse,
        base_url: "http://localhost:3000",
        sse_endpoint: "/sse",
        message_endpoint: "/message"
      )
  
  ## Features
  
  ### Resources
  
  Resources represent data sources that can be read by the client:
  
      # List all resources
      {:ok, resources} = McpClient.list_resources(client)
      
      # Read a specific resource
      {:ok, %{contents: [content]}} = McpClient.read_resource(
        client, 
        "file:///path/to/file"
      )
      
      # Subscribe to resource updates
      :ok = McpClient.subscribe_resource(client, "file:///watched/file")
      
      # Handle notifications via callbacks
      McpClient.on_notification(client, fn notification ->
        case notification.method do
          "notifications/resources/updated" ->
            IO.puts("Resource updated: \#{notification.params.uri}")
          _ -> :ok
        end
      end)
  
  ### Prompts
  
  Prompts are templated messages that can be retrieved and rendered:
  
      # List available prompts
      {:ok, prompts} = McpClient.list_prompts(client)
      
      # Get a specific prompt with arguments
      {:ok, prompt} = McpClient.get_prompt(client, "code-review", %{
        language: "elixir",
        style: "functional"
      })
  
  ### Tools
  
  Tools are functions that the server exposes for execution:
  
      # List available tools
      {:ok, tools} = McpClient.list_tools(client)
      
      # Call a tool
      {:ok, result} = McpClient.call_tool(client, "search_web", %{
        query: "Elixir OTP patterns",
        max_results: 10
      })
      
      # Tools can return text or images
      case result do
        %{content: [%{type: "text", text: text}]} ->
          IO.puts(text)
        %{content: [%{type: "image", data: base64, mimeType: mime}]} ->
          save_image(base64, mime)
      end
  
  ### Sampling
  
  Request LLM completions through the client (if server supports it):
  
      {:ok, completion} = McpClient.create_message(client, %{
        messages: [
          %{role: "user", content: %{type: "text", text: "Hello!"}}
        ],
        modelPreferences: %{
          hints: [%{name: "claude-3-5-sonnet-20241022"}]
        },
        maxTokens: 100
      })
  
  ### Roots
  
  Manage root directories for file system access:
  
      # List current roots
      {:ok, roots} = McpClient.list_roots(client)
      
      # Server can request roots list via notifications
  
  ### Logging
  
  Send and receive structured logs:
  
      # Set logging level
      :ok = McpClient.set_log_level(client, :debug)
      
      # Receive log notifications from server
      McpClient.on_notification(client, fn
        %{method: "notifications/message", params: params} ->
          Logger.log(params.level, params.data)
        _ -> :ok
      end)
  
  ## Telemetry
  
  The library emits telemetry events for monitoring:
  
      [:mcp_client, :request, :start]
      [:mcp_client, :request, :stop]
      [:mcp_client, :request, :exception]
      [:mcp_client, :notification, :received]
      [:mcp_client, :connection, :established]
      [:mcp_client, :connection, :closed]
  
  Attach your telemetry handlers:
  
      :telemetry.attach_many(
        "mcp-handler",
        [
          [:mcp_client, :request, :stop],
          [:mcp_client, :connection, :established]
        ],
        &MyApp.Telemetry.handle_event/4,
        nil
      )
  
  ## Error Handling
  
  All functions return `{:ok, result}` or `{:error, reason}`:
  
      case McpClient.call_tool(client, "unknown_tool", %{}) do
        {:ok, result} ->
          handle_success(result)
          
        {:error, %McpClient.Error{code: -32601}} ->
          IO.puts("Tool not found")
          
        {:error, %McpClient.Error{code: -32603, message: msg}} ->
          Logger.error("Internal error: \#{msg}")
          
        {:error, :timeout} ->
          IO.puts("Request timed out")
          
        {:error, :not_initialized} ->
          IO.puts("Client not yet initialized")
      end
  
  ## Supervision
  
  The client can be supervised in your application tree:
  
      children = [
        {McpClient, 
          name: MyApp.McpClient,
          transport: :stdio,
          command: "python",
          args: ["-m", "my_server"]
        }
      ]
      
      Supervisor.start_link(children, strategy: :one_for_one)
  
  Or use a dynamic supervisor for multiple clients:
  
      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      
      {:ok, client1} = DynamicSupervisor.start_child(supervisor, {
        McpClient,
        transport: :stdio,
        command: "filesystem-server"
      })
      
      {:ok, client2} = DynamicSupervisor.start_child(supervisor, {
        McpClient,
        transport: :sse,
        url: "http://localhost:3000/sse"
      })
  
  ## Advanced Usage
  
  ### Custom Middleware
  
      defmodule MyApp.CustomMiddleware do
        @behaviour McpClient.Middleware
        
        def call(request, next) do
          # Pre-processing
          request = add_custom_header(request)
          
          # Execute request
          result = next.(request)
          
          # Post-processing
          transform_result(result)
        end
      end
      
      McpClient.start_link(
        transport: :stdio,
        command: "server",
        middleware: [
          MyApp.CustomMiddleware,
          McpClient.Middleware.Telemetry,
          McpClient.Middleware.Retry
        ]
      )
  
  ### Graceful Shutdown
  
      # In your application
      def stop(_state) do
        McpClient.list_all()
        |> Enum.each(&McpClient.shutdown/1)
      end
  
  ### Testing
  
  Use the mock server for testing:
  
      defmodule MyAppTest do
        use ExUnit.Case
        
        setup do
          {:ok, client} = McpClient.start_link(
            transport: :test,
            mock_server: McpClient.Test.MockServer
          )
          
          {:ok, client: client}
        end
        
        test "calls tool successfully", %{client: client} do
          McpClient.Test.MockServer.expect(:call_tool, fn "my_tool", _args ->
            {:ok, %{content: [%{type: "text", text: "success"}]}}
          end)
          
          assert {:ok, _} = McpClient.call_tool(client, "my_tool", %{})
        end
      end
  
  ## Protocol Compliance
  
  This library implements MCP protocol version `2024-11-05` and supports:
  
  - ✅ JSON-RPC 2.0 message format
  - ✅ Initialize/initialized handshake
  - ✅ Capability negotiation
  - ✅ Resources (list, read, subscribe, templates)
  - ✅ Prompts (list, get)
  - ✅ Tools (list, call)
  - ✅ Sampling (create_message)
  - ✅ Roots (list, notifications)
  - ✅ Logging (set level, notifications)
  - ✅ Ping/pong health checks
  - ✅ Progress notifications
  - ✅ Cancellation support
  
  ## Links
  
  - [MCP Specification](https://spec.modelcontextprotocol.io/)
  - [GitHub Repository](https://github.com/yourusername/mcp_client)
  - [Hex Package](https://hex.pm/packages/mcp_client)
  - [Documentation](https://hexdocs.pm/mcp_client)
  """

  use GenServer
  
  alias McpClient.{Client, Types, Transport}

  @type client :: pid() | atom()
  @type uri :: String.t()
  @type tool_name :: String.t()
  @type prompt_name :: String.t()

  # Public API

  @doc """
  Starts an MCP client process.
  
  ## Options
  
  Required options vary by transport type:
  
  ### stdio transport
  - `:command` - Executable command to run
  - `:args` - List of command arguments (default: [])
  - `:env` - Environment variables map (default: %{})
  
  ### sse transport
  - `:url` - SSE endpoint URL
  - `:headers` - HTTP headers (default: [])
  
  ### http_sse transport
  - `:base_url` - Base URL for HTTP requests
  - `:sse_endpoint` - SSE endpoint path
  - `:message_endpoint` - Message POST endpoint path
  
  Common options:
  - `:name` - Registered name for the client
  - `:client_info` - Map with `:name` and `:version`
  - `:capabilities` - Client capabilities struct
  - `:timeout` - Request timeout in ms (default: 30_000)
  - `:initialize_timeout` - Initialization timeout (default: 10_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(Client, opts, name: opts[:name])
  end

  @doc """
  Stops the MCP client gracefully.
  """
  @spec stop(client()) :: :ok
  def stop(client) do
    GenServer.stop(client)
  end

  @doc """
  Blocks until the client completes initialization or timeout.
  """
  @spec await_initialized(client(), timeout()) :: :ok | {:error, term()}
  def await_initialized(client, timeout \\ 5000) do
    GenServer.call(client, :await_initialized, timeout)
  end

  ## Resources

  @doc """
  Lists all available resources from the server.
  """
  @spec list_resources(client(), keyword()) :: {:ok, [Types.Resource.t()]} | {:error, term()}
  def list_resources(client, opts \\ []) do
    GenServer.call(client, {:list_resources, opts}, opts[:timeout] || 30_000)
  end

  @doc """
  Reads the contents of a resource by URI.
  """
  @spec read_resource(client(), uri(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_resource(client, uri, opts \\ []) do
    GenServer.call(client, {:read_resource, uri, opts}, opts[:timeout] || 30_000)
  end

  @doc """
  Subscribes to updates for a specific resource.
  """
  @spec subscribe_resource(client(), uri()) :: :ok | {:error, term()}
  def subscribe_resource(client, uri) do
    GenServer.call(client, {:subscribe_resource, uri})
  end

  @doc """
  Unsubscribes from resource updates.
  """
  @spec unsubscribe_resource(client(), uri()) :: :ok | {:error, term()}
  def unsubscribe_resource(client, uri) do
    GenServer.call(client, {:unsubscribe_resource, uri})
  end

  @doc """
  Lists available resource templates.
  """
  @spec list_resource_templates(client()) :: {:ok, list()} | {:error, term()}
  def list_resource_templates(client) do
    GenServer.call(client, :list_resource_templates)
  end

  ## Prompts

  @doc """
  Lists all available prompts from the server.
  """
  @spec list_prompts(client()) :: {:ok, list()} | {:error, term()}
  def list_prompts(client) do
    GenServer.call(client, :list_prompts)
  end

  @doc """
  Gets a specific prompt with optional arguments.
  """
  @spec get_prompt(client(), prompt_name(), map()) :: {:ok, map()} | {:error, term()}
  def get_prompt(client, name, arguments \\ %{}) do
    GenServer.call(client, {:get_prompt, name, arguments})
  end

  ## Tools

  @doc """
  Lists all available tools from the server.
  """
  @spec list_tools(client()) :: {:ok, [Types.Tool.t()]} | {:error, term()}
  def list_tools(client) do
    GenServer.call(client, :list_tools)
  end

  @doc """
  Calls a tool with the given arguments.
  """
  @spec call_tool(client(), tool_name(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_tool(client, name, arguments, opts \\ []) do
    GenServer.call(client, {:call_tool, name, arguments, opts}, opts[:timeout] || 30_000)
  end

  ## Sampling

  @doc """
  Requests an LLM completion from the client.
  """
  @spec create_message(client(), map()) :: {:ok, map()} | {:error, term()}
  def create_message(client, params) do
    GenServer.call(client, {:create_message, params}, 120_000)
  end

  ## Roots

  @doc """
  Lists the current root directories.
  """
  @spec list_roots(client()) :: {:ok, list()} | {:error, term()}
  def list_roots(client) do
    GenServer.call(client, :list_roots)
  end

  ## Logging

  @doc """
  Sets the logging level for server messages.
  """
  @spec set_log_level(client(), atom()) :: :ok | {:error, term()}
  def set_log_level(client, level) when level in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] do
    GenServer.call(client, {:set_log_level, level})
  end

  ## Ping

  @doc """
  Sends a ping to check if the server is responsive.
  """
  @spec ping(client()) :: :ok | {:error, term()}
  def ping(client) do
    GenServer.call(client, :ping, 5_000)
  end

  ## Notifications

  @doc """
  Registers a callback for notifications from the server.
  """
  @spec on_notification(client(), (Types.Notification.t() -> any())) :: :ok
  def on_notification(client, callback) when is_function(callback, 1) do
    GenServer.cast(client, {:register_notification_handler, callback})
  end

  ## Progress

  @doc """
  Registers a callback for progress notifications.
  """
  @spec on_progress(client(), (map() -> any())) :: :ok
  def on_progress(client, callback) when is_function(callback, 1) do
    GenServer.cast(client, {:register_progress_handler, callback})
  end

  ## Utilities

  @doc """
  Returns the current connection state.
  """
  @spec state(client()) :: :initializing | :ready | :closed
  def state(client) do
    GenServer.call(client, :get_state)
  end

  @doc """
  Returns the server's capabilities after initialization.
  """
  @spec server_capabilities(client()) :: {:ok, Types.ServerCapabilities.t()} | {:error, :not_initialized}
  def server_capabilities(client) do
    GenServer.call(client, :get_server_capabilities)
  end

  @doc """
  Returns server implementation info.
  """
  @spec server_info(client()) :: {:ok, Types.Implementation.t()} | {:error, :not_initialized}
  def server_info(client) do
    GenServer.call(client, :get_server_info)
  end
end
```

This gives you a complete public API surface that's idiomatic Elixir, leverages OTP supervision, and covers the full MCP spec. The structure separates concerns cleanly while maintaining the benefits of BEAM concurrency.
