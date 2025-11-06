defmodule MCPClientTest do
  use ExUnit.Case
  doctest MCPClient

  test "greets the world" do
    assert MCPClient.hello() == :world
  end
end
