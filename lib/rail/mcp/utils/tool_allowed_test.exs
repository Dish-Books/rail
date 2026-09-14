defmodule Rail.Mcp.Utils.ToolAllowedTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.ToolAllowed

  test "allows a named tool or every tool on a wildcarded server" do
    assert tool_allowed?(["linear__get_issue"], "linear", "get_issue")
    assert tool_allowed?(["linear__*"], "linear", "anything")
    refute tool_allowed?(["linear__get_issue"], "linear", "delete_issue")
    refute tool_allowed?(["sentry__*"], "linear", "get_issue")
    refute tool_allowed?(nil, "linear", "get_issue")
  end
end
