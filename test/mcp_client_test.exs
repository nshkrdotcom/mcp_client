defmodule McpClientTest do
  use ExUnit.Case
  doctest McpClient

  test "greets the world" do
    assert McpClient.hello() == :world
  end
end
