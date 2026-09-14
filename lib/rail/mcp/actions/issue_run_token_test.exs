defmodule Rail.Mcp.Actions.IssueRunTokenTest do
  use ExUnit.Case, async: true

  alias Rail.Mcp

  test "mints a distinct token with its sha256" do
    {token, hash} = Mcp.issue_run_token()

    assert byte_size(token) >= 43
    assert ^hash = :crypto.hash(:sha256, token)
    refute elem(Mcp.issue_run_token(), 0) == token
  end
end
